# patchy-app-manifests

[patchy] as a self-owned **application image** for the platform clusters. This repo publishes
`oci://<registry>/manifests/patchy`: a cosign-signed OCI artifact holding everything patchy deploys on a cluster (the
chart releases, the secret syncs, the RBAC bindings, the image-verification policy) plus its own flux self-definition.
The terraform modules under `modules/` install it onto a cluster as a self-contained application: they seed the image
once (flux owns it from then on) and create everything it needs outside the cluster - secret containers, IAM grants and
the `patchy-vars` ConfigMap - through the cluster modules' generic `modules/application`. The cluster module itself has
no knowledge of patchy.

Until 4.0 of [flux-manifests] this content lived inside the platform artifact as its `patchy` and `patchy-cloud`
components, elected through `STACK_COMPONENTS`. Splitting it out means an application release and a platform release are
no longer the same release, the platform carries nothing patchy-specific, and a cluster that does not run patchy never
sees its IAM, secrets or SSO wiring.

| repo                            | role                                                                                      |
| ------------------------------- | ----------------------------------------------------------------------------------------- |
| **patchy-app-manifests** (this) | the application image, and the per-cloud terraform modules that install it onto a cluster |
| [flux-manifests]                | the platform: the entrypoint the FluxInstance syncs and the per-component images          |
| [terraform-aws-eks-flux]        | the EKS cluster module; `modules/aws` installs through its `modules/application`          |
| [terraform-google-gke-flux]     | the GKE sibling; `modules/google` installs through its `modules/application`              |

## The seed contract

The cluster modules' `modules/application` creates two objects in `flux-system`, bootstrap-only (the
`application-patchy` helm release, under `ignore_changes = all`), and this image ships the same two objects under
`manifests/flux/` so the first reconcile adopts them. The names are a fixed contract between the three repos:

| object                     | name               | namespace     | owner after hand-over              |
| -------------------------- | ------------------ | ------------- | ---------------------------------- |
| `ResourceSetInputProvider` | `patchy-manifests` | `flux-system` | `Kustomization/patchy`             |
| `ResourceSet`              | `patchy-manifests` | `flux-system` | `Kustomization/patchy`             |
| `OCIRepository`            | `patchy-manifests` | `flux-system` | `ResourceSet/patchy-manifests`     |
| `Kustomization`            | `patchy`           | `flux-system` | `ResourceSet/patchy-manifests`     |
| `ConfigMap` (substitution) | `cluster-vars`     | `flux-system` | terraform (the cluster root)       |
| `ConfigMap` (substitution) | `patchy-vars`      | `flux-system` | terraform (`modules/{aws,google}`) |

- The provider follows the image's **version tags** through `PATCHY_MANIFESTS_SEMVER` (default `<1.0.0 >=0.1.0`); the
  ResourceSet turns the newest match into a digest-pinned, signature-verified `OCIRepository` and the `Kustomization`
  that applies `./deploy/<PLATFORM_TREE>` from it, substituting from `cluster-vars` and `patchy-vars`.
- Both seed objects carry `kustomize.toolkit.fluxcd.io/prune: disabled` (in the seed and in the image): the
  Kustomization applies its own parents, and must never be able to prune them - an image that dropped `flux/` by mistake
  would otherwise garbage-collect itself and every patchy object with it.
- After hand-over the image owns the semver floor, the `dependsOn` gates, the verify identity and the interval; a
  manifests release changes them with no terraform apply. Destroying the patchy module uninstalls the seed: the
  ResourceSet finalizer garbage-collects the Kustomization, whose finalizer prunes patchy.
- A range matching **no** tag empties the ResourceSet, which prunes the application. Keep the floor honest.

## Layout

```text
manifests/                            <- the image root (flux push artifact --path manifests)
  flux/                               the self-definition above (RSIP + ResourceSet)
  deploy/common/                      cloud-neutral: namespaces, chart releases, rbac, policy
  deploy/aws/                         + ../../flux, the aws secret-sync dialect (Secrets Store CSI + SecretSync)
  deploy/google/                      + ../../flux, GKE Integrated Secret Synchronization, HealthCheckPolicies
modules/aws, modules/google           the installers: one module call against a cluster's application_target
scripts/validate.sh, tests/           the render + schema harness (make test)
scripts/publish.sh, .github/workflows the release pipeline (push, sign, tag; GAR and ECR)
```

`deploy/common` may not branch on cloud: the one cloud-shaped value it needs (the KMS URI scheme of the keyed attestor)
keys off `OCI_PROVIDER`, which the aws platform publishes and google leaves to the `gcp` default.

## Installing patchy

patchy installs onto an existing cluster from any root that can read the cluster root's `application_target` output -
usually a root of its own, in another state. The cluster root is not touched: it has no `applications`,
`application_vars`, `workload_grants`, `secret_readers` or `flux.namespaces` entry for patchy, and needs none.

```hcl
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config  = { bucket = "...", key = "clusters/patchy-x.tfstate", region = "eu-west-2" }
}

module "patchy" {
  source = "git::https://github.com/bitwise-media-group/patchy-app-manifests.git//modules/aws?ref=vX.Y.Z"

  cluster     = data.terraform_remote_state.cluster.outputs.application_target
  domain      = "patchy.example.com" # the cluster's served host: dex lives at dex.<host>
  harnesses   = ["claude"]
  claude      = { provider = "anthropic" }
  sso_enabled = true # the cluster elects dex
  evaluation  = { enabled = false }
}
```

The google side is the same call with `//modules/google` and terraform-google-gke-flux's `application_target`;
`claude.provider` is `anthropic` or `vertex` there. Each module calls its cluster repo's `modules/application`, so the
root needs that module's providers: `aws` (cluster account and region) or `google` (cluster project), plus `helm`
pointed at the cluster.

| what                      | aws (`modules/aws`)                                                           | google (`modules/google`)                                    |
| ------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------ |
| seed                      | `application-patchy` release: the RSIP + ResourceSet `patchy-manifests`       | same                                                         |
| `patchy-vars`, namespaces | `application-patchy-inputs` release: the ConfigMap, `patchy`, `patchy-agents` | same                                                         |
| credential containers     | Secrets Manager, `<SECRET_PREFIX><name>`                                      | Secret Manager in `cluster.project`, `<SECRET_PREFIX><name>` |
| secret reads              | IRSA reader roles `<cluster>-secrets-<ns>-patchy-secrets`                     | `secretAccessor` per container for the sync KSA's principal  |
| egress-broker model grant | `<cluster>-patchy-egress-broker` (Pod Identity), under `bedrock`              | `aiplatform.user` for the broker's principal, under `vertex` |

The image url (`oci://<platform_registry>/manifests/patchy`), the secret prefix and the signing mode all come from
`application_target`: on a keyless cluster the seed verifies the image against `signed_identity_subject`, on a KMS-keyed
one against the `cosign-pub` Secret.

Inputs: `cluster`, `domain`, `harnesses`, `claude`, `evaluation`, `sso_enabled`, `egress_policy`, `manifests_semver`,
`signed_identity_subject`, `extra_vars`, and `tags` (aws) or `labels` (google). Outputs: `release`, `vars`, `secrets`,
and `workload_roles` + `secret_reader_roles` (aws) or `workload_members` (google).

The containers' versions are added out of band and destroyed with the module. `sso_enabled` declares no secrets: it adds
the platform's `dex` Kustomization to the seed's `dependsOn` (the image's own Kustomization does the same once it owns
itself) and is required by `evaluation`.

Security Command Center findings reach patchy through
[`modules/scc-notifications`](modules/scc-notifications/README.md), a standalone google-only module (topic, notification
config, OIDC-authenticated push subscription, dead-letter queue) applied on its own after the cluster, by an identity
holding `roles/securitycenter.admin` at the organization. Its pipeline values reach the manifests through `extra_vars`.

patchy lives in exactly one root. modules/application mints the same names a cluster root would for an application it
seeds itself, so a second copy (or a leftover `applications.patchy` in the cluster root) fails loudly on the helm
releases and, on aws, the IAM roles. On google an IAM member binding is shared rather than owned, so destroying one copy
would also remove the other's grant.

### `patchy-vars`

The application's own substitution ConfigMap, terraform-reconciled through `modules/application`'s inputs release. Every
key is application-owned; the manifests read the platform keys from `cluster-vars` and these from `patchy-vars`:

| key                                                            | value                                                                          |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `AGENT_HARNESSES`                                              | sorted, comma-joined harness election; `none` when empty                       |
| `AGENT_EGRESS_POLICY`                                          | `cilium` (aws default), `auto` (google default), `none`, `gke`, `istio`        |
| `PATCHY_EVALUATION`                                            | `"true"` / `"false"`                                                           |
| `PATCHY_DOMAIN`                                                | the served host; must equal the platform's `PLATFORM_DOMAIN`                   |
| `CLAUDE_PROVIDER`, `CLAUDE_ANTHROPIC_AUTH`, `CLAUDE_MODEL_MAP` | the broker's provider knobs                                                    |
| `CLAUDE_BEDROCK_REGION`, `CLAUDE_BEDROCK_REGION_PREFIX`        | aws only (google publishes `CLAUDE_VERTEX_REGION`, `CLAUDE_VERTEX_PROJECT_ID`) |
| `PATCHY_MANIFESTS_SEMVER`                                      | the range the image's own provider follows                                     |
| `SIGNED_IDENTITY_PATCHY_MANIFESTS`                             | the Fulcio subject of this repo's publish workflow                             |

Caller extras (`PATCHY_SEMVER` for the chart range, `PATCHY_FALLBACK_REPOSITORY`, `AGENT_EGRESS_BROAD`, the google
`SCC_*` pipeline values) ride the same ConfigMap through the module's `extra_vars`, which cannot shadow a key above.
Three signing identities are in play and must not be confused: `SIGNED_IDENTITY_PATCHY` (the chart, signed by patchy's
own `helm.yaml`), `SIGNED_IDENTITY_PATCHY_IMAGES` (the images, signed by the shared release workflow) and
`SIGNED_IDENTITY_PATCHY_MANIFESTS` (this image). All three carry `:=` defaults in the manifests.

### What the image reads from the platform

`PLATFORM_COMPONENTS` (whether `dex` is elected: the status page's sign-in, the dex clients, the evaluation controller
and the Kustomization's `dex` dependency all key off it), `PLATFORM_DOMAIN` (the dex issuer), `PLATFORM_TREE` (which
deploy tree, and whether the aws `secret-sync` Kustomization exists to wait on), `PLATFORM_REGISTRY`, `OCI_PROVIDER`,
`ARTIFACT_TAG_PROVIDER`, the `SIGNED_IDENTITY_*` / `COSIGN_PUBLIC_KEY` signing mode, `SECRET_PREFIX`,
`SECRETS_ROLE_PREFIX` (aws), `GCP_PROJECT` (google), `AWS_REGION` (aws), `RBAC_GROUP_*` and `KYVERNO_FAILURE_ACTION`.

## What the image deploys

- **Namespaces** `patchy` (labelled `platform.bitwisemedia.uk/gateway-access: "true"`, which admits its HTTPRoutes to
  the platform Gateway's wildcard listener) and `patchy-agents` (restricted Pod Security). Both are pre-created by
  `modules/application` (labelled `app.kubernetes.io/managed-by: application-patchy`) and adopted here.
- **The charts** (`deploy/common/resourceset.yaml`): `patchy` and `patchy-config` from ghcr, keyless-verified against
  patchy's own chart identity. HTTPRoutes attach by hostname (`integrations.`, `status.`, `evals.` under
  `PATCHY_DOMAIN`); there is no `sectionName`.
- **RBAC** (`rbac.yaml`): RoleBindings under `patchy-*` names onto the chart-rendered `patchy-findings-*` and
  `patchy-evaluations-submitter` ClusterRoles, one per non-empty `RBAC_GROUP_*`. The cluster-wide bindings are the
  platform's.
- **Image verification** (`policy.yaml`): a `PolicyException` in `kyverno` exempts pods in patchy's namespaces from the
  platform's `verify-platform-signature` rule, and the `verify-patchy-signature` ClusterPolicy re-verifies them there -
  ghcr patchy and evolve images against the shared release workflow identity, everything else against the platform
  identity - so every image is still verified by exactly one rule.
- **Dex clients** (`resourceset-dex.yaml`, dex clusters only): see [Dex clients](#dex-clients).
- **Secret syncs** (per cloud): one `SecretProviderClass`/`SecretSync` pair per credential, run as the `patchy-secrets`
  KSAs. `patchy-github` always; the harness credentials by election, the anthropic one only under the anthropic
  provider.
- **GKE HealthCheckPolicies** (google only) for the webhook, status and evaluation backends.

## Dex clients

patchy registers its dex clients itself, as `DexClient` objects the platform's
[dex-client-controller](https://oss.bitwisemedia.uk/dex-client-controller/) turns into dex clients through dex's gRPC
API. They need a flux-manifests release that runs the controller beside dex, and they render only when `dex` is in
`PLATFORM_COMPONENTS`: on a dex-less cluster the `DexClient` CRD does not exist.

| `DexClient` (in `patchy`) | client id       | kind                     | when                       | consumed by                                                                                |
| ------------------------- | --------------- | ------------------------ | -------------------------- | ------------------------------------------------------------------------------------------ |
| `status`                  | `patchy-status` | confidential             | dex elected                | the status server: `status-dex-client` Secret, generated by the controller                 |
| `evolve`                  | `patchy-evolve` | public (PKCE, no secret) | dex elected and evaluation | the evaluation API's `auth.config.oidc.clientID`; evolve reads it from `/api/v1/auth/info` |

Client ids are the controller's `<namespace>-<name>` default; the platform's kyverno policy holds any explicit id to the
same `patchy-` prefix.

The status server's auth mount is a projection: the `patchy-status-auth` ConfigMap (the secretless `config.yaml`,
shipped beside the `DexClient`) plus the `clientSecret` key of `status-dex-client`, mounted as the `client-secret` file
`config.yaml` points at. The chart mounts a single Secret, so a postRenderer on the patchy HelmRelease rewrites the
volume. On a dex cluster the client Secret is required, so the pod waits for the controller rather than starting
half-configured.

To rotate the status client's secret, delete `status-dex-client`. The controller generates a new one and replaces the
client in dex. Then restart the status server, which reads the file at startup:

```sh
kubectl -n patchy delete secret status-dex-client
kubectl -n patchy rollout restart deployment patchy-status-server
```

## Releases

release-please cuts `vX.Y.Z`; `publish.yaml` pushes `manifests/` as `manifests/patchy:X.Y.Z` to every configured
registry, signs each digest keylessly, then moves `staging`; `publish-edge.yaml` pushes `edge-next` on every merge to
main, signs, then moves `edge`; `promote.yaml` moves `stable` behind the `production` environment. Clusters follow
**version tags** through the seed's semver range; the channel tags exist for humans and `flux pull artifact`.

Org variables: `PLATFORM_REGISTRY` + `GCP_WIF_PROVIDER` + `GCP_MANIFEST_PUBLISHER_SA` (GAR; the SA is this repo's own
publisher, set as a repo variable shadowing the org one), and `AWS_MANIFEST_PUBLISHER_ROLE` + `AWS_PLATFORM_REGISTRY` +
`AWS_REGION` (ECR; the role is the artifact-store module's `manifest_publishers["patchy-app-manifests"]`, path-scoped to
`manifests/patchy` so this repo can never overwrite the platform). The ECR branch is skipped when
`AWS_MANIFEST_PUBLISHER_ROLE` is unset.

## Validation

`make test` runs `scripts/validate.sh` (kustomize-builds each deploy tree, substitutes `cluster-vars` + `patchy-vars`
fixtures from `tests/` in strict mode with the null-guard from flux-manifests, asserts the seed contract, renders every
ResourceSet with `flux-operator build resourceset` and the fixtures under `tests/inputs/`, and kubeconforms the lot
against the vendored CRD schemas) and then `terraform test` in both modules. `make lint` is the toolchain's license,
prose, shell, actionlint and kubescape passes.

## Moving patchy out of the cluster root

Before this release `modules/aws` and `modules/google` only produced maps (`namespaces`, `workload_grants`,
`secret_readers`, `application`, `vars`) that the root fed to the cluster module's `applications`, `application_vars`,
`workload_grants`, `workload_identity.secret_readers` and `flux.namespaces`. They now install patchy themselves, and the
inputs that described the cluster (`name`, `project`, `platform_registry`, `secret_prefix`) are replaced by `cluster`,
the cluster root's `application_target`.

The seed release, the namespaces and the IAM roles can't be held by both roots at once, so the move is a reinstall, as
the cluster module's "Moving an application to its own root" describes:

1. Remove every patchy entry from the cluster root (`applications.patchy`, `application_vars.patchy`, the patchy
   `workload_grants`, `secret_readers` and `flux.namespaces`) and apply it. The seed uninstalls and patchy is pruned.
2. Apply `module "patchy"` against the cluster's `application_target`, from the cluster root or a root of its own.

If the old `module "patchy"` lived in the cluster root, its credential containers keep their names, so moving the call
to another root needs the containers moved too (`terraform state mv` across states, or `removed` plus `import`) - or
their versions re-added after the new apply creates them.

## Migrating from flux-manifests 3.x

The cluster module's 4.0 release and flux-manifests 4.0 remove the `patchy` election. On a running cluster: install
patchy as above, then re-point the FluxInstance at the platform entrypoint. The patchy objects already carry owner label
`patchy`, so nothing churns; the former `patchy-cloud` objects relabel. The sequence is written up in the cluster
module's README.

## Migrating to `DexClient`

Before this change, the app modules declared `patchy-status` and `evolve` through `applications.patchy.dex_clients`, and
the cluster module minted `dex-client-patchy-status` in the cloud secret store. terraform-aws-eks-flux 5.0 removes
`dex_clients`. In order:

1. Release flux-manifests with the dex-client-controller and let the cluster pick it up (`dex` Ready,
   `kubectl get crd dexclients.dex.bitwisemedia.uk`).
2. Apply the cluster root on terraform-aws-eks-flux 5.0 with `dex_clients` dropped. `patchy-status` and `evolve` leave
   dex's static clients, the `dex-client-patchy-status` and `patchy-status-auth-config` documents are deleted, and
   `dex_client_versions` is gone from the module.
3. Let the new image reconcile. The `DexClient`s register `patchy-status` (same id, new secret) and `patchy-evolve`, and
   the status server rolls onto the projected mount. The old `patchy-status-auth` SecretSync and its Secret are pruned.

Steps 2 and 3 can land in either order, and each heals once the other arrives: a `DexClient` whose id is still a static
client is refused by dex (static clients are read-only) and retried. Status sign-in fails in between, so keep the two
close. Evolve users run `evolve login` once more afterwards: the evaluation API now expects tokens for `patchy-evolve`,
not `evolve`.

## Documentation

The documentation site at <https://oss.bitwisemedia.uk/patchy-app-manifests/> covers installing patchy, the seed
contract, what the image deploys and the upgrade paths, and embeds each module's README as its reference page. It is
published by the release workflow at each release tag. Preview it with `make serve`. See
[Working on the docs](docs/reference/docs.md).

## Caveats

- **`patchy-vars` is optional to flux, required in practice.** The seed's Kustomization marks the ConfigMap
  `optional: true` so a missing one is not a hard error on the flux side, but `PATCHY_DOMAIN` and friends are bare
  `${VAR}` reads: without the ConfigMap strict substitution fails the Kustomization. The modules always render it, in
  the same apply and ahead of the seed.
- **`PATCHY_DOMAIN` must be the platform's served host.** The platform Gateway's single wildcard listener covers one
  label under `PLATFORM_DOMAIN`, and dex is served at `dex.<PLATFORM_DOMAIN>`.
- **The exception moves the check, it does not remove it** - but only for the two namespaces named in `policy.yaml`. A
  new namespace needs both the exception and the policy widened.
- **The dex clients need the controller.** On a dex cluster whose flux-manifests release predates the
  dex-client-controller, the seeded Kustomization's `dex` dependency is Ready but the `DexClient` CRD is missing, so
  `patchy-dex` fails to apply until the platform catches up.

[patchy]: https://github.com/bitwise-media-group/patchy
[flux-manifests]: https://github.com/bitwise-media-group/flux-manifests
[terraform-aws-eks-flux]: https://github.com/bitwise-media-group/terraform-aws-eks-flux
[terraform-google-gke-flux]: https://github.com/bitwise-media-group/terraform-google-gke-flux
