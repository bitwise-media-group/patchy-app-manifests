# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "cluster" {
  description = <<-EOT
    The cluster to install patchy onto: pass terraform-aws-eks-flux's application_target output verbatim (through
    terraform_remote_state or any other channel). It is handed to that repo's modules/application unchanged, and
    supplies everything patchy used to take as separate inputs - the cluster name (IAM role names), the platform
    registry the image is published beneath (oci://<platform_registry>/manifests/patchy), the SECRET_PREFIX the
    containers are named under and the reader roles are scoped to, the IRSA provider the reader roles trust, and
    the signing mode (keyless clusters verify the image against signed_identity_subject, KMS-keyed clusters
    against the cosign-pub Secret).
  EOT
  type = object({
    name              = string
    namespace         = string
    platform_registry = string
    tree              = string
    issuer            = optional(string)
    keyed             = bool
    oidc_provider_arn = string
    oidc_issuer       = string
    secret_prefix     = string
  })
  nullable = false

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[^/]+", var.cluster.platform_registry))
    error_message = "cluster.platform_registry must be an ECR prefix: <account>.dkr.ecr.<region>.amazonaws.com/<prefix> (is this a terraform-aws-eks-flux application_target?)."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]*$", var.cluster.secret_prefix))
    error_message = "cluster.secret_prefix must use Secrets Manager name characters only ([A-Za-z0-9/_+=.@-])."
  }
}

variable "domain" {
  description = <<-EOT
    The served host patchy's endpoints hang off (integrations.<domain>, status.<domain>, evals.<domain>), published as
    PATCHY_DOMAIN. Pass the cluster's served host (terraform-aws-eks-flux's dns.host, or the zone apex when host is
    unset): the platform Gateway terminates TLS on one wildcard listener (*.<PLATFORM_DOMAIN>), and dex - which the
    status server and evolve authenticate against - is served at dex.<PLATFORM_DOMAIN>, so the two values must be the
    same host.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain))
    error_message = "domain must be a bare DNS name (no scheme, no trailing dot)."
  }
}

variable "harnesses" {
  description = <<-EOT
    The agent harnesses patchy runs (claude, codex, copilot), published as AGENT_HARNESSES. Gates the chart's
    per-harness runners, the harness credential syncs and the containers created here, and derives the sync KSAs that
    get reader roles: claude is brokered (its credential lives in the patchy namespace), codex and copilot mount
    theirs into the agent pods, so electing either adds the patchy-agents reader.
  EOT
  type        = set(string)
  nullable    = false
  default     = ["claude"]

  validation {
    condition     = alltrue([for harness in var.harnesses : contains(["claude", "codex", "copilot"], harness)])
    error_message = "harnesses entries must be harness short names: claude, codex, copilot."
  }
}

variable "claude" {
  description = <<-EOT
    The model provider patchy's egress-broker terminates all claude-runner traffic against, published as the CLAUDE_*
    vars (CLAUDE_PROVIDER, CLAUDE_ANTHROPIC_AUTH, CLAUDE_BEDROCK_REGION, CLAUDE_BEDROCK_REGION_PREFIX,
    CLAUDE_MODEL_MAP). provider anthropic needs the patchy-anthropic-token container (created here, populated out of
    band); provider bedrock needs no secret at all - the broker's KSA gets the Bedrock invoke grant instead (an IAM
    role bound through Pod Identity). Keys are harness-scoped and the knobs provider-prefixed, mirroring the broker's own
    PATCHY_BEDROCK_* env names.
  EOT
  type = object({
    provider              = optional(string, "anthropic") # anthropic | bedrock
    anthropic_auth        = optional(string, "token")     # key | token
    bedrock_region        = optional(string)              # defaults to the provider's region
    bedrock_region_prefix = optional(string)              # inference-profile geo prefix (us/eu/apac)
    model_map             = optional(map(string), {})     # canonical id -> provider model id
  })
  nullable = false
  default  = {}

  validation {
    condition     = contains(["anthropic", "bedrock"], var.claude.provider)
    error_message = "claude.provider must be anthropic or bedrock (vertex needs GCP ambient credentials the broker cannot get on EKS; foundry is deliberately unsupported for now)."
  }

  validation {
    condition     = contains(["key", "token"], var.claude.anthropic_auth)
    error_message = "claude.anthropic_auth must be key or token."
  }

  validation {
    condition     = var.claude.provider == "bedrock" || var.claude.bedrock_region == null
    error_message = "claude.bedrock_region only applies when the provider is bedrock."
  }

  validation {
    condition     = var.claude.provider == "bedrock" || var.claude.bedrock_region_prefix == null
    error_message = "claude.bedrock_region_prefix only applies when the provider is bedrock."
  }
}

variable "evaluation" {
  description = <<-EOT
    evaluation.enabled deploys the evaluation controller - the evolve-facing remote-evaluation API plus the runners
    that execute submitted evaluation units - published as PATCHY_EVALUATION. It requires sso_enabled (the API has no
    unauthenticated posture; evolve authenticates through dex as a public PKCE client, the image's evolve DexClient)
    and at least one harness (the chart refuses an evaluation controller with zero enabled runners).
  EOT
  type = object({
    enabled = optional(bool, false)
  })
  nullable = false
  default  = {}

  validation {
    condition     = !var.evaluation.enabled || var.sso_enabled
    error_message = "evaluation requires sso_enabled - the evaluation API has no unauthenticated posture; evolve authenticates through dex."
  }

  validation {
    condition     = !var.evaluation.enabled || length(var.harnesses) > 0
    error_message = "evaluation requires at least one harness - the chart refuses an evaluation controller with zero enabled runners."
  }
}

variable "sso_enabled" {
  description = <<-EOT
    Whether the cluster deploys dex (terraform-aws-eks-flux's sso.enabled). When on, the seed's Kustomization waits on the
    platform's dex Kustomization, whose dex-client-controller registers the DexClients the image ships (patchy-status,
    and patchy-evolve under evaluation). When off, the status server runs rollups-only (no sign-in) and evaluation is
    refused.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "egress_policy" {
  description = <<-EOT
    The agent-egress network-policy dialect the patchy chart renders (none, cilium, gke, istio, auto), published as
    AGENT_EGRESS_POLICY. cilium by default: terraform-aws-eks-flux installs Cilium as the only CNI, so the answer is
    known for certain and the chart's auto probe need not be trusted.
  EOT
  type        = string
  nullable    = false
  default     = "cilium"

  validation {
    condition     = contains(["none", "cilium", "gke", "istio", "auto"], var.egress_policy)
    error_message = "egress_policy must be none, cilium, gke, istio or auto."
  }
}

variable "manifests_semver" {
  description = <<-EOT
    The semver range the seed follows for this application's manifests image (version tags of
    oci://<cluster.platform_registry>/manifests/patchy), published as PATCHY_MANIFESTS_SEMVER for the image's own
    ResourceSetInputProvider and as the seed's range. A range matching no tag empties the seed and prunes the
    application - keep it bounded and honest. Constraint order matters: a range must not start with '>' (YAML would
    read the unquoted form as a folded block scalar).
  EOT
  type        = string
  nullable    = false
  default     = "<1.0.0 >=0.1.0"

  validation {
    condition     = !startswith(var.manifests_semver, ">")
    error_message = "manifests_semver must not start with '>' - put the upper bound first (e.g. '<1.0.0 >=0.1.0')."
  }
}

variable "signed_identity_subject" {
  description = <<-EOT
    Fulcio certificate-subject regexp (keyless cosign) of the workflow that signs this application's manifests image -
    this repo's publish.yaml at a release tag by default; pass the publish-edge identity for a cluster following edge
    builds. Published as SIGNED_IDENTITY_PATCHY_MANIFESTS and used as the seed's verify subject. Ignored on KMS-keyed
    clusters (cluster.keyed), which verify against the signing key's public half instead.
  EOT
  type        = string
  nullable    = false
  default     = "^https://github\\.com/bitwise-media-group/patchy-app-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
}

variable "extra_vars" {
  description = <<-EOT
    Further patchy-vars keys merged beside the ones this module owns - the caller extras the manifests read with :=
    defaults (PATCHY_SEMVER for the chart range, PATCHY_FALLBACK_REPOSITORY, AGENT_EGRESS_BROAD, ...). Keys must be
    SCREAMING_SNAKE_CASE and must not be one of this module's own keys (AGENT_HARNESSES, AGENT_EGRESS_POLICY,
    PATCHY_EVALUATION, PATCHY_DOMAIN, PATCHY_MANIFESTS_SEMVER, SIGNED_IDENTITY_PATCHY_MANIFESTS, CLAUDE_*): set those
    through their own inputs.
  EOT
  type        = map(string)
  nullable    = false
  default     = {}

  validation {
    condition     = alltrue([for key in keys(var.extra_vars) : can(regex("^[A-Z][A-Z0-9_]*$", key))])
    error_message = "extra_vars must use SCREAMING_SNAKE_CASE keys (^[A-Z][A-Z0-9_]*$), the shape flux substitution reads."
  }

  validation {
    condition = alltrue([
      for key in keys(var.extra_vars) :
      !contains(["AGENT_HARNESSES", "AGENT_EGRESS_POLICY", "PATCHY_EVALUATION", "PATCHY_DOMAIN", "PATCHY_MANIFESTS_SEMVER", "SIGNED_IDENTITY_PATCHY_MANIFESTS"], key)
      && !startswith(key, "CLAUDE_")
    ])
    error_message = "extra_vars must not set a key this module owns (AGENT_HARNESSES, AGENT_EGRESS_POLICY, PATCHY_EVALUATION, PATCHY_DOMAIN, PATCHY_MANIFESTS_SEMVER, SIGNED_IDENTITY_PATCHY_MANIFESTS, CLAUDE_*) - use its input instead."
  }
}

variable "tags" {
  description = "Tags applied to every secret, IAM role and Pod Identity association."
  type        = map(string)
  nullable    = false
  default     = {}
}
