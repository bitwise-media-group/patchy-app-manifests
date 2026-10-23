# To DexClient

Before this change, the app modules declared `patchy-status` and `evolve` through `applications.patchy.dex_clients`, and
the cluster module minted `dex-client-patchy-status` in the cloud secret store. terraform-aws-eks-flux 5.0 removes
`dex_clients`. In order:

1. Release flux-manifests with the dex-client-controller and let the cluster pick it up: `dex` is Ready, and
   `kubectl get crd dexclients.dex.bitwisemedia.uk` finds the CRD.
2. Apply the cluster root on terraform-aws-eks-flux 5.0 with `dex_clients` dropped. `patchy-status` and `evolve` leave
   dex's static clients, the `dex-client-patchy-status` and `patchy-status-auth-config` documents are deleted, and
   `dex_client_versions` is gone from the module.
3. Let the new image reconcile. The `DexClient`s register `patchy-status` (same id, new secret) and `patchy-evolve`, and
   the status server rolls onto the projected mount. The old `patchy-status-auth` SecretSync and its Secret are pruned.

Steps 2 and 3 can land in either order, and each heals once the other arrives: dex refuses a `DexClient` whose id is
still a static client (static clients are read-only), and the controller retries. Status sign-in fails in between, so
keep the two close.

!!! note "Evolve users log in again"

    Run `evolve login` once more afterwards: the evaluation API now expects tokens for `patchy-evolve`, not `evolve`.

See [Dex clients](../concepts/dex-clients.md) for how the clients work now.
