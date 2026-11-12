# What the image deploys

Everything below is applied by `Kustomization/patchy` from `./<PLATFORM_TREE>` (`./aws` or `./google`). The common tree
is cloud-neutral; the per-cloud trees add their secret-sync dialect.

## Namespaces

`patchy` and `patchy-agents` (restricted Pod Security). `patchy` carries the label
`platform.bitwisemedia.uk/gateway-access: "true"`, which admits its HTTPRoutes to the platform Gateway's wildcard
listener.

Both are pre-created by `modules/application` (labelled `app.kubernetes.io/managed-by: application-patchy`) and adopted
here.

## The charts

`common/resourceset.yaml` releases `patchy` and `patchy-config` from ghcr, keyless-verified against patchy's own chart
identity. HTTPRoutes attach by hostname (`integrations.`, `status.` and `evals.` under `PATCHY_DOMAIN`); there is no
`sectionName`.

## RBAC

`rbac.yaml` holds RoleBindings, under `patchy-*` names, onto the chart-rendered `patchy-findings-*` and
`patchy-evaluations-submitter` ClusterRoles: one per non-empty `RBAC_GROUP_*`. The cluster-wide bindings are the
platform's.

## Image verification

`policy.yaml` moves patchy's images to their own verification rule without dropping the check:

- a `policies.kyverno.io/v1` `PolicyException` in `kyverno` exempts patchy's namespaces from the platform's
  `verify-platform-signature` `ImageValidatingPolicy`;
- the `verify-patchy-signature` `ImageValidatingPolicy` re-verifies them there: ghcr patchy and evolve images against
  the shared release workflow identity, everything else against the platform identity.

Every image is still verified by exactly one policy. The exception is scoped on `request.namespace`, so it also covers
the Deployments, ReplicaSets, Jobs and CronJobs Kyverno checks on the pods' behalf, not just the pods.

A pre-CEL `kyverno.io/v2` exception ships alongside it, so patchy stays exempt on clusters still running the platform's
old `ClusterPolicy`. It covers the auto-generated controller rules as well; before, every patchy Deployment and
ReplicaSet was reported failing. It goes once every cluster runs the platform's CEL release.

## Dex clients

Rendered on dex clusters only (`resourceset-dex.yaml`). See [Dex clients](dex-clients.md).

## Secret syncs

One `SecretProviderClass`/`SecretSync` pair per credential, run as the `patchy-secrets` KSAs. `patchy-github` is always
synced; the harness credentials (`patchy-anthropic`, `patchy-openai`, `patchy-copilot`) by election, and the anthropic
one only under the anthropic provider.

=== "aws"

    The Secrets Store CSI driver with the AWS provider and `SecretSync`, reading Secrets Manager through the IRSA
    reader roles `modules/aws` creates.

=== "google"

    GKE Integrated Secret Synchronization, reading Secret Manager with the `secretAccessor` grants `modules/google`
    creates.

## GKE HealthCheckPolicies

Google only: `HealthCheckPolicy` objects for the webhook, status and evaluation backends.
