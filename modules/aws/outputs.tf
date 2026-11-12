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
    The credential containers the image syncs, keyed by unprefixed name: the (prefixed) Secrets Manager name, the ARN
    (null when create_secrets is false - the module did not create it) and the name-pattern ARN
    (arn:...:secret:<name>-??????) that matches it either way, for wiring further IAM in the caller (e.g. a
    maintainer's PutSecretValue rotation grant). Listed in both modes, so a durable root can create exactly this set.
    Every version is added out of band: aws secretsmanager put-secret-value --secret-id <name>.
  EOT
  value = {
    for name in keys(local.containers) : name => {
      arn         = var.create_secrets ? aws_secretsmanager_secret.main[name].arn : null
      arn_pattern = local.arn_patterns[name]
      name        = "${var.cluster.secret_prefix}${name}"
    }
  }
}
