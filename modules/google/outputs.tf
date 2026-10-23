# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "release" {
  description = "The bootstrap-only seed release (application-patchy) in the cluster's flux namespace."
  value       = module.application.release
}

output "vars" {
  description = <<-EOT
    The patchy-vars ConfigMap contents: every application-owned key the manifests substitute - AGENT_*, PATCHY_*,
    CLAUDE_*, the manifests semver range and signing subject - plus extra_vars.
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
    The created credential containers, keyed by unprefixed name: the resource id and the (prefixed) secret id. Versions
    are added out of band: gcloud secrets versions add <id> --data-file=-.
  EOT
  value = {
    for name in keys(local.containers) : name => {
      id        = google_secret_manager_secret.main[name].id
      secret_id = google_secret_manager_secret.main[name].secret_id
    }
  }
}
