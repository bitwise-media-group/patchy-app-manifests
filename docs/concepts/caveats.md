# Caveats

- **`patchy-vars` is optional to flux, required in practice.** The seed's Kustomization marks the ConfigMap
  `optional: true`, so a missing one isn't a hard error on the flux side. But `PATCHY_DOMAIN` and friends are bare
  `${VAR}` reads: without the ConfigMap, strict substitution fails the Kustomization. The modules always render it, in
  the same apply and ahead of the seed.
- **`PATCHY_DOMAIN` must be the platform's served host.** The platform Gateway's single wildcard listener covers one
  label under `PLATFORM_DOMAIN`, and dex is served at `dex.<PLATFORM_DOMAIN>`.
- **The exception moves the check, it doesn't remove it**, but only for the two namespaces named in `policy.yaml`. A new
  namespace needs both the exception and the policy widened. See [Image verification](deploys.md#image-verification).
- **The dex clients need the controller.** On a dex cluster whose flux-manifests release predates the
  dex-client-controller, the seeded Kustomization's `dex` dependency is Ready but the `DexClient` CRD is missing, so
  `patchy-dex` fails to apply until the platform catches up.
- **A range matching no tag uninstalls patchy.** An empty match empties the ResourceSet, which prunes the application.
  See [The seed contract](seed-contract.md#how-the-hand-over-works).
- **One root only.** A second copy of the module (or a leftover `applications.patchy` in the cluster root) fails on the
  helm releases and, on aws, the IAM roles. On google, destroying one copy also removes the other's IAM grant. See
  [Installing patchy](../getting-started/installing.md#one-root-only).
