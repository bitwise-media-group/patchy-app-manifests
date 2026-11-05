# Keeping credential containers in a durable root

This release moves the cluster pins forward and adds `create_secrets` to `modules/aws` and `modules/google`. With
`create_secrets = false`, the credential containers can live in a durable root (an accounts or project root that
outlives every cluster) while the root that calls `module "patchy"` makes only the grants. The out-of-band versions then
survive a cluster rebuild, and nobody has to add them again.

## The new pins

| Module           | Calls                                           | At                                         |
| ---------------- | ----------------------------------------------- | ------------------------------------------ |
| `modules/google` | terraform-google-gke-flux `modules/application` | `d74b5323d24b795a644a184a57aa85ea109e3de2` |
| `modules/aws`    | terraform-aws-eks-flux `modules/application`    | `b1aa85c0553db184f6d2eb73c3403d76a9a9857b` |

- **google:** the provider range rises to `>= 7.46, < 8.10`, matching the cluster module. A root with a lock file pinned
  below that range needs `terraform init -upgrade`.
- **`application_target` grew node facts.** The cluster roots now also export `location`, `node_locations` and
  `node_service_account` (google) or the node role, subnets and endpoint (aws). Keep passing the output verbatim. patchy
  reads none of them.
- **Capacity isn't patchy's concern.** terraform-aws-eks-flux's `modules/application` no longer takes `node_groups`.
  `modules/aws` never passed it, so nothing changes here. If patchy needs dedicated nodes, call the cluster repository's
  `modules/node-group` (aws) or `modules/node-pool` (google) beside `module "patchy"`, from the same
  `application_target`.
- **aws clusters publish more Karpenter vars.** `KARPENTER_AMI_SELECTOR_TERMS` and `KARPENTER_AMI_FAMILY` now sit beside
  `KARPENTER_AMI_ALIAS` in `cluster-vars`. patchy doesn't read them. The validation harness's `tests/aws.env` carries
  them so the platform contract stays complete.

## `create_secrets`

`create_secrets` is a bool that defaults to `true`, and it can't be null. At `true`, the module behaves exactly as
before. At `false`:

- The module creates no containers.
- The grants stay, by name. On google, every container gets a `roles/secretmanager.secretAccessor` member for the
  federated principal of its sync KSA, on `projects/<cluster.project>/secrets/<SECRET_PREFIX><name>`. On aws, the reader
  roles `<cluster>-secrets-<ns>-patchy-secrets` already read every secret under `<SECRET_PREFIX>` by name pattern.
  Secrets Manager ARNs end in a random `-XXXXXX` suffix, so a name pattern is the only grant that matches a container
  this module didn't create.
- The container set is the same, and it follows the same elections. The `secrets` output lists it in both modes, keyed
  by unprefixed name. On google it carries `id` and `secret_id`. On aws it carries `name`, `arn` (null when the module
  didn't create the container) and `arn_pattern`
  (`arn:<partition>:secretsmanager:<region>:<account>:secret:<name>-??????`).

The durable root must create exactly these names. On aws, it must use the account and region of the patchy root's
provider. On google, it must use `cluster.project`.

| Container (unprefixed)          | Present when                                                             | Read by (google KSA / aws reader) |
| ------------------------------- | ------------------------------------------------------------------------ | --------------------------------- |
| `patchy-github-app-id`          | always                                                                   | `patchy/patchy-secrets`           |
| `patchy-github-app-private-key` | always                                                                   | `patchy/patchy-secrets`           |
| `patchy-webhook-secret`         | always                                                                   | `patchy/patchy-secrets`           |
| `patchy-anthropic-token`        | `claude` elected and `claude.provider` is `anthropic` (either auth mode) | `patchy/patchy-secrets`           |
| `patchy-openai-token`           | `codex` elected                                                          | `patchy-agents/patchy-secrets`    |
| `patchy-copilot-token`          | `copilot` elected                                                        | `patchy-agents/patchy-secrets`    |

Each one is named `<SECRET_PREFIX><name>`. The defaults (`harnesses = ["claude"]`, provider `anthropic`) need the first
four. `sso_enabled` and `evaluation` add no containers. patchy's dex clients are `DexClient` objects whose secrets the
dex-client-controller generates in-cluster, and the dex connector's own containers belong to the cluster repository's
`modules/sso-secrets`.

=== "google"

    ```hcl
    # durable root
    locals {
      patchy_containers = toset([
        "patchy-github-app-id", "patchy-github-app-private-key", "patchy-webhook-secret", "patchy-anthropic-token",
      ])
    }

    resource "google_secret_manager_secret" "patchy" {
      for_each = local.patchy_containers

      project   = "my-cluster-project"              # the cluster's project
      secret_id = "${var.secret_prefix}${each.key}" # the cluster's SECRET_PREFIX

      replication {
        auto {}
      }
    }

    # cluster-side root
    module "patchy" {
      source = "git::https://github.com/bitwise-media-group/patchy-app-manifests.git//modules/google?ref=vX.Y.Z"

      cluster        = data.terraform_remote_state.cluster.outputs.application_target
      domain         = "patchy.example.com"
      create_secrets = false
    }
    ```

=== "aws"

    ```hcl
    # durable root, in the cluster's account and region
    resource "aws_secretsmanager_secret" "patchy" {
      for_each = toset([
        "patchy-github-app-id", "patchy-github-app-private-key", "patchy-webhook-secret", "patchy-anthropic-token",
      ])

      name = "${var.secret_prefix}${each.key}" # the cluster's SECRET_PREFIX
    }

    # cluster-side root
    module "patchy" {
      source = "git::https://github.com/bitwise-media-group/patchy-app-manifests.git//modules/aws?ref=vX.Y.Z"

      cluster        = data.terraform_remote_state.cluster.outputs.application_target
      domain         = "patchy.example.com"
      create_secrets = false
    }
    ```

On google, the grant fails until the container exists, so apply the durable root first. On aws, the reader role's grant
is a pattern and sits inert until a matching secret appears.

## Moving containers this module already created

Flipping an existing `module "patchy"` to `create_secrets = false` drops the containers from its configuration. On its
own, the next apply would destroy them, and their versions with them. Hand them over first:

1. In the durable root, declare the containers and adopt them with `import` blocks. The id is
   `projects/<project>/secrets/<secret_id>` on google and the secret's ARN on aws. Apply. For a moment both states hold
   the containers, and neither changes them.
2. In the patchy root, set `create_secrets = false` and forget the containers without destroying them:
   `terraform state rm 'module.patchy.google_secret_manager_secret.main'` (google) or
   `terraform state rm 'module.patchy.aws_secretsmanager_secret.main'` (aws).
3. Plan the patchy root. It should create and destroy nothing but whatever else you changed. On google, the grants keep
   their addresses and their `secret_id`, so they plan no change. Apply.

## From terraform-google-gke-flux's `patchy` input and `modules/secrets`

terraform-google-gke-flux 5690292 removed the cluster root's `patchy` input, `workload_identity.patchy_egress_broker`,
and the patchy half of `modules/secrets`, which became `modules/sso-secrets` (dex connector containers only). To move,
settle the grants before the containers:

- **Settings:** `patchy` maps onto `modules/google`'s inputs.

  | Removed (cluster root)                     | `modules/google`                                            |
  | ------------------------------------------ | ----------------------------------------------------------- |
  | `patchy.harnesses`                         | `harnesses`                                                 |
  | `patchy.claude.provider.name`              | `claude.provider`                                           |
  | `patchy.claude.provider.anthropic_auth`    | `claude.anthropic_auth`                                     |
  | `patchy.claude.provider.vertex_region`     | `claude.vertex_region`                                      |
  | `patchy.claude.provider.vertex_project_id` | `claude.vertex_project_id`                                  |
  | `patchy.claude.provider.model_map`         | `claude.model_map`                                          |
  | `patchy.evaluation.enabled`                | `evaluation.enabled`                                        |
  | `workload_identity.patchy_egress_broker`   | automatic under `claude.provider = "vertex"`                |
  | `sso.clients` `patchy-status`              | the image's `DexClient` (see [To DexClient](dex-client.md)) |
  | `sso.enabled`                              | also set `sso_enabled = true`                               |

  Pass the cluster's served host as `domain`. [Moving out of the cluster root](cluster-root.md) covers the reinstall.

- **Containers:** once the old grants are out of the durable root's state (below), keep the containers there. The old
  `modules/secrets` call already lives in a durable root. Point the call at `modules/sso-secrets` and drop
  `stack_components`, `agent_harnesses` and `claude_provider`. The dex containers keep their addresses (`main` and
  `sync` in both modules). Move each `patchy-*` container to a resource of the root's own, so it isn't destroyed:

  ```hcl
  moved {
    from = module.secrets.google_secret_manager_secret.main["patchy-github-app-id"]
    to   = google_secret_manager_secret.patchy["patchy-github-app-id"]
  }
  # ... one per patchy-* container
  ```

- **Grants:** the grants now belong to the patchy root. Apply `module "patchy"` with `create_secrets = false` first.
  `google_secret_manager_secret_iam_member` is non-authoritative, so re-adding a member that's already bound changes
  nothing. Then forget the old grants in the durable root rather than destroying them. `removed` can't name single
  instances, and `module.secrets.google_secret_manager_secret_iam_member.sync` still holds the dex grants, so remove
  them from state:
  `terraform state rm 'module.secrets.google_secret_manager_secret_iam_member.sync["patchy-github-app-id"]'`, and so on
  for each `patchy-*` key. Do this before applying the durable root on `modules/sso-secrets`. Otherwise that apply
  destroys the bindings the patchy root just made.
