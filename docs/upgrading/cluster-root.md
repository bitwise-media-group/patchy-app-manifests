# Moving out of the cluster root

Before this release, `modules/aws` and `modules/google` only produced maps (`namespaces`, `workload_grants`,
`secret_readers`, `application`, `vars`) that the root fed to the cluster module's `applications`, `application_vars`,
`workload_grants`, `workload_identity.secret_readers` and `flux.namespaces`. They now install patchy themselves. The
inputs that described the cluster (`name`, `project`, `platform_registry`, `secret_prefix`) are replaced by `cluster`,
the cluster root's `application_target`.

The seed release, the namespaces and the IAM roles can't be held by both roots at once, so the move is a reinstall, as
the cluster module's "Moving an application to its own root" describes:

1. Remove every patchy entry from the cluster root (`applications.patchy`, `application_vars.patchy`, the patchy
   `workload_grants`, `secret_readers` and `flux.namespaces`) and apply it. The seed uninstalls and patchy is pruned.
2. Apply `module "patchy"` against the cluster's `application_target`, from the cluster root or a root of its own. See
   [Installing patchy](../getting-started/installing.md).

!!! note "Credential containers keep their names"

    If the old `module "patchy"` lived in the cluster root, its credential containers keep their names. Moving the
    call to another root needs the containers moved too (`terraform state mv` across states, or `removed` plus
    `import`), or their versions re-added after the new apply creates them.
