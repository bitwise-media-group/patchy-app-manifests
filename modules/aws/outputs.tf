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

output "workload_roles" {
  description = <<-EOT
    The Pod Identity-bound IAM role ARNs, keyed by grant: patchy-egress-broker (the Bedrock invoke grant) exactly when
    claude.provider is bedrock.
  EOT
  value       = module.application.workload_roles
}

output "secret_reader_roles" {
  description = <<-EOT
    The podless secret-sync reader role ARNs, keyed <namespace>/<service_account>: patchy/patchy-secrets always, plus
    patchy-agents/patchy-secrets under codex or copilot.
  EOT
  value       = module.application.secret_reader_roles
}

output "secrets" {
  description = <<-EOT
    The created credential containers, keyed by unprefixed name: the ARN and the (prefixed) Secrets Manager name, for
    wiring further IAM in the caller (e.g. a maintainer's PutSecretValue rotation grant). Every version is added out
    of band: aws secretsmanager put-secret-value --secret-id <name>.
  EOT
  value = {
    for name in keys(local.containers) : name => {
      arn  = aws_secretsmanager_secret.main[name].arn
      name = aws_secretsmanager_secret.main[name].name
    }
  }
}
