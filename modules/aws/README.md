# modules/aws

patchy on AWS, installed onto a [terraform-aws-eks-flux] cluster as a self-contained application. The cluster root never
learns patchy exists: this module takes the cluster root's `application_target` output and installs everything through
that repo's [`modules/application`][application] - the seed (`application-patchy`), the `patchy-vars` ConfigMap, the
pre-created `patchy` / `patchy-agents` namespaces, the podless IRSA reader roles patchy's secret syncs assume, and the
egress-broker's Bedrock grant when elected. It also creates the credential containers the manifests image syncs, under
the cluster's `SECRET_PREFIX`.

```hcl
module "patchy" {
  source = "git::https://github.com/bitwise-media-group/patchy-app-manifests.git//modules/aws?ref=vX.Y.Z"

  cluster = data.terraform_remote_state.cluster.outputs.application_target
  domain  = "patchy.example.com"
}
```

The root needs an `aws` provider in the cluster's account and region and a `helm` provider pointed at the cluster. The
credential versions are added out of band, so destroying the module destroys them with their containers. See the
repository README for the `patchy-vars` contract.

[terraform-aws-eks-flux]: https://github.com/bitwise-media-group/terraform-aws-eks-flux
[application]: https://github.com/bitwise-media-group/terraform-aws-eks-flux/tree/main/modules/application

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| aws | >= 6.0, < 7.0 |
| helm | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| application | git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/application | 5892b39460b33f3ac152afd1fb2f5b7758f406d0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_secretsmanager_secret.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.bedrock_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster | The cluster to install patchy onto: pass terraform-aws-eks-flux's application\_target output verbatim (through<br/>terraform\_remote\_state or any other channel). It is handed to that repo's modules/application unchanged, and<br/>supplies everything patchy used to take as separate inputs - the cluster name (IAM role names), the platform<br/>registry the image is published beneath (oci://<platform\_registry>/manifests/patchy), the SECRET\_PREFIX the<br/>containers are named under and the reader roles are scoped to, the IRSA provider the reader roles trust, and<br/>the signing mode (keyless clusters verify the image against signed\_identity\_subject, KMS-keyed clusters<br/>against the cosign-pub Secret). | <pre>object({<br/>    name              = string<br/>    namespace         = string<br/>    platform_registry = string<br/>    tree              = string<br/>    issuer            = optional(string)<br/>    keyed             = bool<br/>    oidc_provider_arn = string<br/>    oidc_issuer       = string<br/>    secret_prefix     = string<br/>  })</pre> | n/a | yes |
| domain | The served host patchy's endpoints hang off (integrations.<domain>, status.<domain>, evals.<domain>), published as<br/>PATCHY\_DOMAIN. Pass the cluster's served host (terraform-aws-eks-flux's dns.host, or the zone apex when host is<br/>unset): the platform Gateway terminates TLS on one wildcard listener (*.<PLATFORM\_DOMAIN>), and dex - which the<br/>status server and evolve authenticate against - is served at dex.<PLATFORM\_DOMAIN>, so the two values must be the<br/>same host. | `string` | n/a | yes |
| claude | The model provider patchy's egress-broker terminates all claude-runner traffic against, published as the CLAUDE\_*<br/>vars (CLAUDE\_PROVIDER, CLAUDE\_ANTHROPIC\_AUTH, CLAUDE\_BEDROCK\_REGION, CLAUDE\_BEDROCK\_REGION\_PREFIX,<br/>CLAUDE\_MODEL\_MAP). provider anthropic needs the patchy-anthropic-token container (created here, populated out of<br/>band); provider bedrock needs no secret at all - the broker's KSA gets the Bedrock invoke grant instead (an IAM<br/>role bound through Pod Identity). Keys are harness-scoped and the knobs provider-prefixed, mirroring the broker's own<br/>PATCHY\_BEDROCK\_* env names. | <pre>object({<br/>    provider              = optional(string, "anthropic") # anthropic | bedrock<br/>    anthropic_auth        = optional(string, "token")     # key | token<br/>    bedrock_region        = optional(string)              # defaults to the provider's region<br/>    bedrock_region_prefix = optional(string)              # inference-profile geo prefix (us/eu/apac)<br/>    model_map             = optional(map(string), {})     # canonical id -> provider model id<br/>  })</pre> | `{}` | no |
| egress\_policy | The agent-egress network-policy dialect the patchy chart renders (none, cilium, gke, istio, auto), published as<br/>AGENT\_EGRESS\_POLICY. cilium by default: terraform-aws-eks-flux installs Cilium as the only CNI, so the answer is<br/>known for certain and the chart's auto probe need not be trusted. | `string` | `"cilium"` | no |
| evaluation | evaluation.enabled deploys the evaluation controller - the evolve-facing remote-evaluation API plus the runners<br/>that execute submitted evaluation units - published as PATCHY\_EVALUATION. It requires sso\_enabled (the API has no<br/>unauthenticated posture; evolve authenticates through dex as a public PKCE client, the image's evolve DexClient)<br/>and at least one harness (the chart refuses an evaluation controller with zero enabled runners). | <pre>object({<br/>    enabled = optional(bool, false)<br/>  })</pre> | `{}` | no |
| extra\_vars | Further patchy-vars keys merged beside the ones this module owns - the caller extras the manifests read with :=<br/>defaults (PATCHY\_SEMVER for the chart range, PATCHY\_FALLBACK\_REPOSITORY, AGENT\_EGRESS\_BROAD, ...). Keys must be<br/>SCREAMING\_SNAKE\_CASE and must not be one of this module's own keys (AGENT\_HARNESSES, AGENT\_EGRESS\_POLICY,<br/>PATCHY\_EVALUATION, PATCHY\_DOMAIN, PATCHY\_MANIFESTS\_SEMVER, SIGNED\_IDENTITY\_PATCHY\_MANIFESTS, CLAUDE\_*): set those<br/>through their own inputs. | `map(string)` | `{}` | no |
| harnesses | The agent harnesses patchy runs (claude, codex, copilot), published as AGENT\_HARNESSES. Gates the chart's<br/>per-harness runners, the harness credential syncs and the containers created here, and derives the sync KSAs that<br/>get reader roles: claude is brokered (its credential lives in the patchy namespace), codex and copilot mount<br/>theirs into the agent pods, so electing either adds the patchy-agents reader. | `set(string)` | <pre>[<br/>  "claude"<br/>]</pre> | no |
| manifests\_semver | The semver range the seed follows for this application's manifests image (version tags of<br/>oci://<cluster.platform\_registry>/manifests/patchy), published as PATCHY\_MANIFESTS\_SEMVER for the image's own<br/>ResourceSetInputProvider and as the seed's range. A range matching no tag empties the seed and prunes the<br/>application - keep it bounded and honest. Constraint order matters: a range must not start with '>' (YAML would<br/>read the unquoted form as a folded block scalar). | `string` | `"<1.0.0 >=0.1.0"` | no |
| signed\_identity\_subject | Fulcio certificate-subject regexp (keyless cosign) of the workflow that signs this application's manifests image -<br/>this repo's publish.yaml at a release tag by default; pass the publish-edge identity for a cluster following edge<br/>builds. Published as SIGNED\_IDENTITY\_PATCHY\_MANIFESTS and used as the seed's verify subject. Ignored on KMS-keyed<br/>clusters (cluster.keyed), which verify against the signing key's public half instead. | `string` | `"^https://github.com/bitwise-media-group/patchy-app-manifests/.github/workflows/publish.yaml@refs/tags/v.+$"` | no |
| sso\_enabled | Whether the cluster deploys dex (terraform-aws-eks-flux's sso.enabled). When on, the seed's Kustomization waits on the<br/>platform's dex Kustomization, whose dex-client-controller registers the DexClients the image ships (patchy-status,<br/>and patchy-evolve under evaluation). When off, the status server runs rollups-only (no sign-in) and evaluation is<br/>refused. | `bool` | `false` | no |
| tags | Tags applied to every secret, IAM role and Pod Identity association. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| release | The bootstrap-only seed release (application-patchy) in the cluster's flux namespace. |
| secret\_reader\_roles | The podless secret-sync reader role ARNs, keyed <namespace>/<service\_account>: patchy/patchy-secrets always, plus<br/>patchy-agents/patchy-secrets under codex or copilot. |
| secrets | The created credential containers, keyed by unprefixed name: the ARN and the (prefixed) Secrets Manager name, for<br/>wiring further IAM in the caller (e.g. a maintainer's PutSecretValue rotation grant). Every version is added out<br/>of band: aws secretsmanager put-secret-value --secret-id <name>. |
| vars | The patchy-vars ConfigMap contents: every application-owned key the manifests substitute - AGENT\_*, PATCHY\_*,<br/>CLAUDE\_*, the manifests semver range and signing subject - plus extra\_vars. |
| workload\_roles | The Pod Identity-bound IAM role ARNs, keyed by grant: patchy-egress-broker (the Bedrock invoke grant) exactly when<br/>claude.provider is bedrock. |
<!-- END_TF_DOCS -->
