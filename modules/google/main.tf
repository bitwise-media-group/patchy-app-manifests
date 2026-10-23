# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# patchy on Google Cloud, installed onto a terraform-google-gke-flux cluster
# as a self-contained application: the cluster root never learns patchy
# exists. The shape mirrors modules/aws exactly - same inputs but for the
# provider pair, same patchy-vars keys but for CLAUDE_VERTEX_* in place of
# CLAUDE_BEDROCK_* - so a root composes the two the same way on either cloud:
#
#   module "patchy" {
#     source  = ".../patchy-app-manifests//modules/google"
#     cluster = data.terraform_remote_state.cluster.outputs.application_target
#     domain  = "..."
#   }
#
# Everything that touches the cluster goes through terraform-google-gke-flux's
# modules/application (the module call below): the seed (application-patchy),
# the patchy-vars ConfigMap, the pre-created patchy / patchy-agents
# namespaces and, under the vertex provider, the egress-broker's
# aiplatform.user grant.
#
# The Secret Manager containers the image syncs
# (deploy/google/resourceset-secrets.yaml) are created here in
# cluster.project, named under cluster.secret_prefix. The read grant is
# resource-side: GKE Integrated Secret Synchronization reads each container
# as the sync KSA's federated principal, so every container carries a
# secretAccessor member for the KSA that syncs it.
#
# patchy's dex clients are not declared here: the image ships them as
# DexClient objects (deploy/common/resourceset-dex.yaml), and the platform's
# dex-client-controller generates their secrets in-cluster.
#
# The credential VERSIONS are added out of band (gcloud secrets versions add -
# never terraform state), so destroying this module destroys them with the
# containers.

locals {
  vertex = var.claude.provider == "vertex"

  wi_prefix = "principal://iam.googleapis.com/projects/${var.cluster.project_number}/locations/global/workloadIdentityPools/${var.cluster.workload_pool}/subject"

  # container name -> the KSA subject that syncs it.
  containers = merge(
    {
      patchy-github-app-id          = "ns/patchy/sa/patchy-secrets"
      patchy-github-app-private-key = "ns/patchy/sa/patchy-secrets"
      patchy-webhook-secret         = "ns/patchy/sa/patchy-secrets"
    },
    contains(var.harnesses, "claude") && !local.vertex ? {
      patchy-anthropic-token = "ns/patchy/sa/patchy-secrets"
    } : {},
    contains(var.harnesses, "codex") ? {
      patchy-openai-token = "ns/patchy-agents/sa/patchy-secrets"
    } : {},
    contains(var.harnesses, "copilot") ? {
      patchy-copilot-token = "ns/patchy-agents/sa/patchy-secrets"
    } : {},
  )

  vars = {
    AGENT_HARNESSES     = coalesce(join(",", sort(tolist(var.harnesses))), "none")
    AGENT_EGRESS_POLICY = var.egress_policy
    PATCHY_EVALUATION   = var.evaluation.enabled ? "true" : "false"
    PATCHY_DOMAIN       = var.domain

    CLAUDE_PROVIDER          = var.claude.provider
    CLAUDE_ANTHROPIC_AUTH    = var.claude.anthropic_auth
    CLAUDE_VERTEX_REGION     = var.claude.vertex_region != null ? var.claude.vertex_region : ""
    CLAUDE_VERTEX_PROJECT_ID = local.vertex ? coalesce(var.claude.vertex_project_id, var.cluster.project) : ""
    CLAUDE_MODEL_MAP         = join(",", [for k in sort(keys(var.claude.model_map)) : "${k}=${var.claude.model_map[k]}"])

    PATCHY_MANIFESTS_SEMVER          = var.manifests_semver
    SIGNED_IDENTITY_PATCHY_MANIFESTS = var.signed_identity_subject
  }

  # The egress-broker's Vertex grant, present exactly when the provider is
  # vertex (anthropic authenticates with a synced credential).
  workload_grants = local.vertex ? {
    patchy-egress-broker = {
      namespace       = "patchy"
      service_account = "patchy-egress-broker"
      roles           = ["roles/aiplatform.user"]
      project         = coalesce(var.claude.vertex_project_id, var.cluster.project)
    }
  } : {}
}

resource "google_secret_manager_secret" "main" {
  for_each = local.containers

  project   = var.cluster.project
  secret_id = "${var.cluster.secret_prefix}${each.key}"
  labels    = var.labels

  replication {
    auto {}
  }
}

# Accessor only: the sync KSAs read versions, nothing else. Version WRITES
# stay a human/out-of-band concern.
resource "google_secret_manager_secret_iam_member" "sync" {
  for_each = local.containers

  project   = var.cluster.project
  secret_id = google_secret_manager_secret.main[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.wi_prefix}/${each.value}"
}

# The cluster-facing half, through the cluster module's own standalone
# application module: every name it mints (release application-patchy,
# ConfigMap patchy-vars) is the one the manifests expect.
module "application" {
  source = "git::https://github.com/bitwise-media-group/terraform-google-gke-flux.git//modules/application?ref=5690292e74c82b4735bb66bad2ad331a01fc0e22"

  name    = "patchy"
  cluster = var.cluster

  image = {
    url    = "oci://${var.cluster.platform_registry}/manifests/patchy"
    semver = var.manifests_semver
    # the first install also waits on the secret syncs materialising the
    # chart's Secrets (the image's own Kustomization carries the same 10m)
    timeout = "10m"
    # mirrors the image's own Kustomization: GKE ships its secret sync with
    # the cluster, so there is no secret-sync Kustomization to wait on; dex
    # when it is elected, so the DexClient CRD exists before patchy-dex
    # applies
    depends_on = concat(["kyverno-policies", "gateway"], var.sso_enabled ? ["dex"] : [])
    # keyless clusters pin this repo's publish identity; KMS-keyed clusters
    # verify against the cosign-pub Secret instead
    verify = {
      subject = var.cluster.keyed ? null : var.signed_identity_subject
      keyed   = var.cluster.keyed
    }
  }

  vars            = merge(var.extra_vars, local.vars)
  namespaces      = ["patchy", "patchy-agents"]
  workload_grants = local.workload_grants
}
