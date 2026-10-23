# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# patchy on AWS, installed onto a terraform-aws-eks-flux cluster as a
# self-contained application: the cluster root never learns patchy exists.
# A root of its own (or any root holding the cluster's application_target)
# composes it:
#
#   module "patchy" {
#     source  = ".../patchy-app-manifests//modules/aws"
#     cluster = data.terraform_remote_state.cluster.outputs.application_target
#     domain  = "..."
#   }
#
# Everything patchy needs outside the image is here, and everything that
# touches the cluster goes through terraform-aws-eks-flux's
# modules/application (the module call below):
#
#   - the Secrets Manager containers the image syncs
#     (deploy/aws/resourceset-secrets.yaml), named under cluster.secret_prefix
#   - the seed (application-patchy: the patchy-manifests RSIP + ResourceSet
#     the image adopts on its first reconcile), the patchy-vars ConfigMap and
#     the pre-created patchy / patchy-agents namespaces
#   - the podless IRSA reader roles the sync KSAs assume
#     (<cluster>-secrets-<ns>-<sa>, what ${SECRETS_ROLE_PREFIX}<ns>-<sa>
#     resolves to in the manifests)
#   - the egress-broker's Bedrock grant, under that provider
#
# patchy's dex clients are not declared here: the image ships them as
# DexClient objects (deploy/common/resourceset-dex.yaml), and the platform's
# dex-client-controller generates their secrets in-cluster.
#
# The credential VERSIONS are added out of band (aws secretsmanager
# put-secret-value - never terraform state), so destroying this module
# destroys them with the containers. The containers carry no resource
# policy: the read grant is identity-side, the reader roles scoping
# GetSecretValue to ${cluster.secret_prefix}*.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  bedrock = var.claude.provider == "bedrock"

  # A non-brokered harness (codex, copilot) mounts its credential into the
  # agent pods, so its sync runs in the agent namespace.
  agent_namespace_secrets = length(setintersection(var.harnesses, ["codex", "copilot"])) > 0

  # secret name -> description. The gating mirrors the manifests exactly: a
  # secret no sync references is never created, and every referenced secret
  # exists (a SecretProviderClass naming an absent secret syncs nothing but
  # errors forever).
  containers = merge(
    # The GitHub App credential (webhook validation, issue projection,
    # repository clone/push), synced unconditionally.
    {
      patchy-github-app-id          = "The patchy GitHub App's numeric id"
      patchy-github-app-private-key = "The patchy GitHub App's private key (PEM)"
      patchy-webhook-secret         = "The patchy GitHub App's webhook secret"
    },

    # The Anthropic credential, consumed by the egress broker in the patchy
    # namespace and only when the claude runner's provider is anthropic: a
    # bedrock cluster authenticates with the broker's Pod Identity and needs
    # no secret at all.
    contains(var.harnesses, "claude") && !local.bedrock ? {
      patchy-anthropic-token = "The Anthropic credential the egress broker injects (claude setup-token OAuth token or API key)"
    } : {},

    # The non-brokered runners' model credentials, mounted into the agent
    # pods themselves.
    contains(var.harnesses, "codex") ? {
      patchy-openai-token = "The OpenAI platform API key the codex CLI authenticates with"
    } : {},
    contains(var.harnesses, "copilot") ? {
      patchy-copilot-token = "The Copilot CLI's fine-grained GitHub token (no repository permissions)"
    } : {},
  )


  # The application's own ConfigMap (patchy-vars), substituted into the
  # manifests alongside cluster-vars. Same conventions as the platform
  # contract: comma-joined sorted lists, the reserved name "none" for an
  # empty election (an empty string would re-trigger the manifests' :=
  # default), "true"/"false" literals for booleans, empty strings for knobs
  # that do not apply.
  vars = {
    AGENT_HARNESSES     = coalesce(join(",", sort(tolist(var.harnesses))), "none")
    AGENT_EGRESS_POLICY = var.egress_policy
    PATCHY_EVALUATION   = var.evaluation.enabled ? "true" : "false"
    PATCHY_DOMAIN       = var.domain

    CLAUDE_PROVIDER              = var.claude.provider
    CLAUDE_ANTHROPIC_AUTH        = var.claude.anthropic_auth
    CLAUDE_BEDROCK_REGION        = local.bedrock ? coalesce(var.claude.bedrock_region, data.aws_region.current.region) : ""
    CLAUDE_BEDROCK_REGION_PREFIX = var.claude.bedrock_region_prefix != null ? var.claude.bedrock_region_prefix : ""
    CLAUDE_MODEL_MAP             = join(",", [for k in sort(keys(var.claude.model_map)) : "${k}=${var.claude.model_map[k]}"])

    PATCHY_MANIFESTS_SEMVER          = var.manifests_semver
    SIGNED_IDENTITY_PATCHY_MANIFESTS = var.signed_identity_subject
  }

  # The podless sync KSAs: the patchy-namespace reader always (the GitHub
  # App sync, the brokered anthropic credential), the agent-namespace
  # reader only when a non-brokered harness mounts its credential into the
  # agent pods. The manifests' service-accounts.yaml annotates the same
  # pairs with ${SECRETS_ROLE_PREFIX}<ns>-<sa>.
  secret_readers = concat(
    [{ namespace = "patchy", service_account = "patchy-secrets" }],
    local.agent_namespace_secrets ? [{ namespace = "patchy-agents", service_account = "patchy-secrets" }] : [],
  )

  # The egress-broker's Bedrock invoke grant, present exactly when the
  # provider is bedrock (anthropic authenticates with a synced credential).
  workload_grants = {
    for document in data.aws_iam_policy_document.bedrock_invoke : "patchy-egress-broker" => {
      namespace       = "patchy"
      service_account = "patchy-egress-broker"
      policy          = document.json
    }
  }
}

resource "aws_secretsmanager_secret" "main" {
  for_each = local.containers

  name        = "${var.cluster.secret_prefix}${each.key}"
  description = "${each.value}. Versions arrive out of band; readable by patchy's secret-sync reader roles on ${var.cluster.name}."

  tags = var.tags
}

# The egress-broker's Bedrock invoke grant, Anthropic models only. The
# foundation-model ARN is region-wildcarded because cross-region inference
# profiles invoke foundation models in sibling regions of the profile's geo
# (and foundation-model ARNs carry an empty account field); the
# inference-profile ARN stays pinned to the provider's region and account.
# Handed to modules/application as a workload grant: it mints the IAM role
# <cluster>-patchy-egress-broker and the Pod Identity association for
# patchy/patchy-egress-broker.
data "aws_iam_policy_document" "bedrock_invoke" {
  for_each = toset(local.bedrock ? ["true"] : [])

  statement {
    sid    = "InvokeAnthropicModels"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/anthropic.*",
      "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:inference-profile/*.anthropic.*",
    ]
  }
}

# The cluster-facing half, through the cluster module's own standalone
# application module: every name it mints (release application-patchy,
# ConfigMap patchy-vars, roles <cluster>-<key>) is the one the manifests
# expect.
module "application" {
  source = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/application?ref=5892b39460b33f3ac152afd1fb2f5b7758f406d0"

  name    = "patchy"
  cluster = var.cluster

  image = {
    url    = "oci://${var.cluster.platform_registry}/manifests/patchy"
    semver = var.manifests_semver
    # the first install also waits on the secret syncs materialising the
    # chart's Secrets (the image's own Kustomization carries the same 10m)
    timeout = "10m"
    # mirrors the image's own Kustomization: dex too when it is elected, so
    # the DexClient CRD exists before patchy-dex applies
    depends_on = concat(["kyverno-policies", "gateway", "secret-sync"], var.sso_enabled ? ["dex"] : [])
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
  secret_readers  = local.secret_readers

  tags = var.tags
}
