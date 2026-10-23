# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "cluster" {
  description = <<-EOT
    The cluster to install patchy onto: pass terraform-google-gke-flux's application_target output verbatim (through
    terraform_remote_state or any other channel). It is handed to that repo's modules/application unchanged, and
    supplies everything patchy used to take as separate inputs - the project the containers live in, the platform
    registry the image is published beneath (oci://<platform_registry>/manifests/patchy), the SECRET_PREFIX the
    containers are named under, the project number and Workload Identity pool the sync KSAs' federated principals
    are composed from, and the signing mode (keyless clusters verify the image against signed_identity_subject,
    KMS-keyed clusters against the cosign-pub Secret).
  EOT
  type = object({
    name              = string
    namespace         = string
    platform_registry = string
    tree              = string
    issuer            = optional(string)
    keyed             = bool
    project           = string
    project_number    = string
    workload_pool     = string
    secret_prefix     = string
  })
  nullable = false

  validation {
    condition     = can(regex("^[a-z0-9-]+-docker\\.pkg\\.dev/[^/]+/[^/]+$", var.cluster.platform_registry))
    error_message = "cluster.platform_registry must be an Artifact Registry docker repository prefix: <location>-docker.pkg.dev/<project>/<repository> (is this a terraform-google-gke-flux application_target?)."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]*$", var.cluster.secret_prefix))
    error_message = "cluster.secret_prefix must use Secret Manager id characters only ([A-Za-z0-9_-])."
  }
}

variable "domain" {
  description = <<-EOT
    The served host patchy's endpoints hang off (integrations.<domain>, status.<domain>, evals.<domain>), published as
    PATCHY_DOMAIN. Pass the cluster's served host (terraform-google-gke-flux's dns.host, or the zone apex when host
    is unset): the platform Gateway terminates TLS on one wildcard listener (*.<PLATFORM_DOMAIN>), and dex is served
    at dex.<PLATFORM_DOMAIN>, so the two values must be the same host.
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
    per-harness runners, the harness credential syncs and the containers (and accessor grants) created here.
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
    vars (CLAUDE_PROVIDER, CLAUDE_ANTHROPIC_AUTH, CLAUDE_VERTEX_REGION, CLAUDE_VERTEX_PROJECT_ID, CLAUDE_MODEL_MAP).
    provider anthropic needs the patchy-anthropic-token container (created here, populated out of band); provider
    vertex needs no secret - the broker's KSA gets aiplatform.user in the serving project instead, as a direct
    Workload Identity Federation principal.
  EOT
  type = object({
    provider          = optional(string, "anthropic") # anthropic | vertex
    anthropic_auth    = optional(string, "token")     # key | token
    vertex_region     = optional(string)              # defaults to the chart's own
    vertex_project_id = optional(string)              # defaults to cluster.project
    model_map         = optional(map(string), {})     # canonical id -> provider model id
  })
  nullable = false
  default  = {}

  validation {
    condition     = contains(["anthropic", "vertex"], var.claude.provider)
    error_message = "claude.provider must be anthropic or vertex (bedrock needs AWS ambient credentials the broker cannot get on GKE)."
  }

  validation {
    condition     = contains(["key", "token"], var.claude.anthropic_auth)
    error_message = "claude.anthropic_auth must be key or token."
  }

  validation {
    condition     = var.claude.provider == "vertex" || var.claude.vertex_region == null
    error_message = "claude.vertex_region only applies when the provider is vertex."
  }

  validation {
    condition     = var.claude.provider == "vertex" || var.claude.vertex_project_id == null
    error_message = "claude.vertex_project_id only applies when the provider is vertex."
  }
}

variable "evaluation" {
  description = <<-EOT
    evaluation.enabled deploys the evaluation controller, published as PATCHY_EVALUATION. It requires sso_enabled
    (evolve authenticates through dex as a public PKCE client, the image's evolve DexClient) and at least one harness.
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
    Whether the cluster deploys dex (terraform-google-gke-flux's sso.enabled). When on, the seed's Kustomization waits
    on the platform's dex Kustomization, whose dex-client-controller registers the DexClients the image ships
    (patchy-status, and patchy-evolve under evaluation). When off, the status server runs rollups-only and evaluation
    is refused.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "egress_policy" {
  description = <<-EOT
    The agent-egress network-policy dialect the patchy chart renders (none, cilium, gke, istio, auto), published as
    AGENT_EGRESS_POLICY. auto by default: on GKE the chart probes the cluster for FQDNNetworkPolicy support; pin gke
    where the cluster is known to enforce it.
  EOT
  type        = string
  nullable    = false
  default     = "auto"

  validation {
    condition     = contains(["none", "cilium", "gke", "istio", "auto"], var.egress_policy)
    error_message = "egress_policy must be none, cilium, gke, istio or auto."
  }
}

variable "manifests_semver" {
  description = "The semver range the seed follows for the manifests image (PATCHY_MANIFESTS_SEMVER); a range matching no tag prunes the application."
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
    Fulcio certificate-subject regexp of the workflow that signs the manifests image (SIGNED_IDENTITY_PATCHY_MANIFESTS,
    and the seed's verify subject); this repo's publish.yaml at a release tag by default. Ignored on KMS-keyed clusters
    (cluster.keyed), which verify against the signing key's public half instead.
  EOT
  type        = string
  nullable    = false
  default     = "^https://github\\.com/bitwise-media-group/patchy-app-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
}

variable "extra_vars" {
  description = <<-EOT
    Further patchy-vars keys merged beside the ones this module owns - the caller extras the manifests read with :=
    defaults (PATCHY_SEMVER for the chart range, PATCHY_FALLBACK_REPOSITORY, AGENT_EGRESS_BROAD, the SCC_* pipeline
    values from modules/scc-notifications, ...). Keys must be SCREAMING_SNAKE_CASE and must not be one of this
    module's own keys (AGENT_HARNESSES, AGENT_EGRESS_POLICY, PATCHY_EVALUATION, PATCHY_DOMAIN, PATCHY_MANIFESTS_SEMVER,
    SIGNED_IDENTITY_PATCHY_MANIFESTS, CLAUDE_*): set those through their own inputs.
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

variable "labels" {
  description = "Labels applied to every secret container."
  type        = map(string)
  nullable    = false
  default     = {}
}
