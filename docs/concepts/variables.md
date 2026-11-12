# Substitution variables

`Kustomization/patchy` substitutes from two ConfigMaps in `flux-system`: the platform's `cluster-vars` and the
application's own `patchy-vars`. The manifests read the platform keys from the first and the application keys from the
second.

## `patchy-vars`

The application's own substitution ConfigMap, reconciled by terraform through `modules/application`'s inputs release.
Every key is application-owned:

| Key                                                            | Value                                                                          |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `AGENT_HARNESSES`                                              | sorted, comma-joined harness election; `none` when empty                       |
| `AGENT_EGRESS_POLICY`                                          | `cilium` (aws default), `auto` (google default), `none`, `gke`, `istio`        |
| `PATCHY_EVALUATION`                                            | `"true"` / `"false"`                                                           |
| `PATCHY_DOMAIN`                                                | the served host; must equal the platform's `PLATFORM_DOMAIN`                   |
| `CLAUDE_PROVIDER`, `CLAUDE_ANTHROPIC_AUTH`, `CLAUDE_MODEL_MAP` | the broker's provider knobs                                                    |
| `CLAUDE_BEDROCK_REGION`, `CLAUDE_BEDROCK_REGION_PREFIX`        | aws only (google publishes `CLAUDE_VERTEX_REGION`, `CLAUDE_VERTEX_PROJECT_ID`) |

Caller extras ride the same ConfigMap through the module's `extra_vars`, which can't shadow a key above: `PATCHY_SEMVER`
for the chart range, `PATCHY_FALLBACK_REPOSITORY`, `AGENT_EGRESS_BROAD`, and the google `SCC_*` pipeline values.

## Signing identities

Two signing identities are in play in the manifests, and they must not be confused:

| Key                             | Signs      | Signed by                   |
| ------------------------------- | ---------- | --------------------------- |
| `SIGNED_IDENTITY_PATCHY`        | the chart  | patchy's own `helm.yaml`    |
| `SIGNED_IDENTITY_PATCHY_IMAGES` | the images | the shared release workflow |

Both carry `:=` defaults in the manifests. This image itself is verified by the seed, against the modules'
`signed_identity_subject` (see [Releases](releases.md#signing)).

## What the image reads from the platform

From `cluster-vars`:

| Key                                                                                      | What it decides                                                                                                                                         |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PLATFORM_COMPONENTS`                                                                    | whether `dex` is elected: the status page's sign-in, the dex clients, the evaluation controller and the Kustomization's `dex` dependency all key off it |
| `PLATFORM_DOMAIN`                                                                        | the dex issuer                                                                                                                                          |
| `PLATFORM_TREE`                                                                          | which tree to apply (`./aws`, `./google`), and whether the aws `secret-sync` Kustomization exists to wait on                                            |
| `PLATFORM_REGISTRY`, `OCI_PROVIDER`, `ARTIFACT_TAG_PROVIDER`                             | where the image lives and how its tags are listed; `OCI_PROVIDER` also picks the keyed attestor's KMS URI scheme                                        |
| `SIGNED_IDENTITY_*`, `COSIGN_PUBLIC_KEY`                                                 | the cluster's signing mode, keyless or KMS-keyed                                                                                                        |
| `SECRET_PREFIX`, `SECRETS_ROLE_PREFIX` (aws), `GCP_PROJECT` (google), `AWS_REGION` (aws) | where the credential containers live and who may read them                                                                                              |
| `RBAC_GROUP_*`, `KYVERNO_FAILURE_ACTION`                                                 | the RoleBinding subjects, and whether the image policy enforces or audits                                                                               |
