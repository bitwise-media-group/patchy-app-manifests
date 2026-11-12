# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "release" {
  description = "The seed release (application-patchy) in the cluster's flux namespace, reconciled by every apply."
  value       = module.application.release
}

output "vars" {
  description = <<-EOT
    The patchy-vars ConfigMap contents: every application-owned key the manifests substitute - AGENT_*, PATCHY_*,
    and CLAUDE_* - plus extra_vars.
  EOT
  value       = merge(var.extra_vars, local.vars)
}

output "workload_members" {
  description = <<-EOT
    The direct Workload Identity Federation principal of each workload grant, keyed by grant: patchy-egress-broker
    (aiplatform.user in the serving project) exactly when claude.provider is vertex.
  EOT
  value       = module.application.workload_members
}

output "secrets" {
  description = <<-EOT
    The credential containers the image syncs, keyed by unprefixed name: the resource id
    (projects/<project>/secrets/<secret_id>) and the (prefixed) secret id. Listed whether this module created them or
    (create_secrets = false) only granted on them, so a durable root can create exactly this set. Versions are added
    out of band: gcloud secrets versions add <secret_id> --project <project> --data-file=-.
  EOT
  value = {
    for name in keys(local.containers) : name => {
      id        = var.create_secrets ? google_secret_manager_secret.main[name].id : "projects/${var.cluster.project}/secrets/${var.cluster.secret_prefix}${name}"
      secret_id = "${var.cluster.secret_prefix}${name}"
    }
  }
}
