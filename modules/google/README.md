# modules/google

patchy on Google Cloud, installed onto a [terraform-google-gke-flux] cluster as a self-contained application. The
cluster root never learns patchy exists: this module takes the cluster root's `application_target` output and installs
everything through that repo's [`modules/application`][application] - the seed (`application-patchy`), the
`patchy-vars` ConfigMap, the pre-created `patchy` / `patchy-agents` namespaces, and the egress-broker's Vertex grant
when elected. It also creates the credential containers the manifests image syncs, under the cluster's `SECRET_PREFIX`
and in its project, each with a `secretAccessor` grant for the federated principal of the KSA that syncs it.

```hcl
module "patchy" {
  source = "git::https://github.com/bitwise-media-group/patchy-app-manifests.git//modules/google?ref=vX.Y.Z"

  cluster = data.terraform_remote_state.cluster.outputs.application_target
  domain  = "patchy.example.com"
}
```

The root needs a `google` provider for the cluster's project and a `helm` provider pointed at the cluster. The
credential versions are added out of band, so destroying the module destroys them with their containers. See the
repository README for the `patchy-vars` contract.

[terraform-google-gke-flux]: https://github.com/bitwise-media-group/terraform-google-gke-flux
[application]: https://github.com/bitwise-media-group/terraform-google-gke-flux/tree/main/modules/application

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.46, < 8.6 |
| helm | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.46, < 8.6 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| application | git::https://github.com/bitwise-media-group/terraform-google-gke-flux.git//modules/application | 5690292e74c82b4735bb66bad2ad331a01fc0e22 |

## Resources

| Name | Type |
| ---- | ---- |
| [google_secret_manager_secret.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.sync](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster | The cluster to install patchy onto: pass terraform-google-gke-flux's application\_target output verbatim (through<br/>terraform\_remote\_state or any other channel). It is handed to that repo's modules/application unchanged, and<br/>supplies everything patchy used to take as separate inputs - the project the containers live in, the platform<br/>registry the image is published beneath (oci://<platform\_registry>/manifests/patchy), the SECRET\_PREFIX the<br/>containers are named under, the project number and Workload Identity pool the sync KSAs' federated principals<br/>are composed from, and the signing mode (keyless clusters verify the image against signed\_identity\_subject,<br/>KMS-keyed clusters against the cosign-pub Secret). | <pre>object({<br/>    name              = string<br/>    namespace         = string<br/>    platform_registry = string<br/>    tree              = string<br/>    issuer            = optional(string)<br/>    keyed             = bool<br/>    project           = string<br/>    project_number    = string<br/>    workload_pool     = string<br/>    secret_prefix     = string<br/>  })</pre> | n/a | yes |
| domain | The served host patchy's endpoints hang off (integrations.<domain>, status.<domain>, evals.<domain>), published as<br/>PATCHY\_DOMAIN. Pass the cluster's served host (terraform-google-gke-flux's dns.host, or the zone apex when host<br/>is unset): the platform Gateway terminates TLS on one wildcard listener (*.<PLATFORM\_DOMAIN>), and dex is served<br/>at dex.<PLATFORM\_DOMAIN>, so the two values must be the same host. | `string` | n/a | yes |
| claude | The model provider patchy's egress-broker terminates all claude-runner traffic against, published as the CLAUDE\_*<br/>vars (CLAUDE\_PROVIDER, CLAUDE\_ANTHROPIC\_AUTH, CLAUDE\_VERTEX\_REGION, CLAUDE\_VERTEX\_PROJECT\_ID, CLAUDE\_MODEL\_MAP).<br/>provider anthropic needs the patchy-anthropic-token container (created here, populated out of band); provider<br/>vertex needs no secret - the broker's KSA gets aiplatform.user in the serving project instead, as a direct<br/>Workload Identity Federation principal. | <pre>object({<br/>    provider          = optional(string, "anthropic") # anthropic | vertex<br/>    anthropic_auth    = optional(string, "token")     # key | token<br/>    vertex_region     = optional(string)              # defaults to the chart's own<br/>    vertex_project_id = optional(string)              # defaults to cluster.project<br/>    model_map         = optional(map(string), {})     # canonical id -> provider model id<br/>  })</pre> | `{}` | no |
| egress\_policy | The agent-egress network-policy dialect the patchy chart renders (none, cilium, gke, istio, auto), published as<br/>AGENT\_EGRESS\_POLICY. auto by default: on GKE the chart probes the cluster for FQDNNetworkPolicy support; pin gke<br/>where the cluster is known to enforce it. | `string` | `"auto"` | no |
| evaluation | evaluation.enabled deploys the evaluation controller, published as PATCHY\_EVALUATION. It requires sso\_enabled<br/>(evolve authenticates through dex as a public PKCE client, the image's evolve DexClient) and at least one harness. | <pre>object({<br/>    enabled = optional(bool, false)<br/>  })</pre> | `{}` | no |
| extra\_vars | Further patchy-vars keys merged beside the ones this module owns - the caller extras the manifests read with :=<br/>defaults (PATCHY\_SEMVER for the chart range, PATCHY\_FALLBACK\_REPOSITORY, AGENT\_EGRESS\_BROAD, the SCC\_* pipeline<br/>values from modules/scc-notifications, ...). Keys must be SCREAMING\_SNAKE\_CASE and must not be one of this<br/>module's own keys (AGENT\_HARNESSES, AGENT\_EGRESS\_POLICY, PATCHY\_EVALUATION, PATCHY\_DOMAIN, PATCHY\_MANIFESTS\_SEMVER,<br/>SIGNED\_IDENTITY\_PATCHY\_MANIFESTS, CLAUDE\_*): set those through their own inputs. | `map(string)` | `{}` | no |
| harnesses | The agent harnesses patchy runs (claude, codex, copilot), published as AGENT\_HARNESSES. Gates the chart's<br/>per-harness runners, the harness credential syncs and the containers (and accessor grants) created here. | `set(string)` | <pre>[<br/>  "claude"<br/>]</pre> | no |
| labels | Labels applied to every secret container. | `map(string)` | `{}` | no |
| manifests\_semver | The semver range the seed follows for the manifests image (PATCHY\_MANIFESTS\_SEMVER); a range matching no tag prunes the application. | `string` | `"<1.0.0 >=0.1.0"` | no |
| signed\_identity\_subject | Fulcio certificate-subject regexp of the workflow that signs the manifests image (SIGNED\_IDENTITY\_PATCHY\_MANIFESTS,<br/>and the seed's verify subject); this repo's publish.yaml at a release tag by default. Ignored on KMS-keyed clusters<br/>(cluster.keyed), which verify against the signing key's public half instead. | `string` | `"^https://github.com/bitwise-media-group/patchy-app-manifests/.github/workflows/publish.yaml@refs/tags/v.+$"` | no |
| sso\_enabled | Whether the cluster deploys dex (terraform-google-gke-flux's sso.enabled). When on, the seed's Kustomization waits<br/>on the platform's dex Kustomization, whose dex-client-controller registers the DexClients the image ships<br/>(patchy-status, and patchy-evolve under evaluation). When off, the status server runs rollups-only and evaluation<br/>is refused. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| release | The bootstrap-only seed release (application-patchy) in the cluster's flux namespace. |
| secrets | The created credential containers, keyed by unprefixed name: the resource id and the (prefixed) secret id. Versions<br/>are added out of band: gcloud secrets versions add <id> --data-file=-. |
| vars | The patchy-vars ConfigMap contents: every application-owned key the manifests substitute - AGENT\_*, PATCHY\_*,<br/>CLAUDE\_*, the manifests semver range and signing subject - plus extra\_vars. |
| workload\_members | The direct Workload Identity Federation principal of each workload grant, keyed by grant: patchy-egress-broker<br/>(aiplatform.user in the serving project) exactly when claude.provider is vertex. |
<!-- END_TF_DOCS -->
