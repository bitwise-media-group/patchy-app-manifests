# From flux-manifests 3.x

The cluster module's 4.0 release and flux-manifests 4.0 remove the `patchy` election (the `patchy` and `patchy-cloud`
components selected through `STACK_COMPONENTS`).

On a running cluster:

1. [Install patchy](../getting-started/installing.md) as a standalone application.
2. Re-point the FluxInstance at the platform entrypoint.

The patchy objects already carry the owner label `patchy`, so nothing churns; the former `patchy-cloud` objects relabel.
The full sequence is written up in the cluster module's README.
