# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked aws and helm providers: no
# credentials, no API calls. These assert the two contracts this module
# carries - the secret-sync contract with the manifests (which containers
# each election creates, and which KSAs read them) and the application
# contract with terraform-aws-eks-flux's modules/application (the seed it
# hands over, the patchy-vars keys and the identities it mints).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "eu-west-2"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "helm" {}

variables {
  # terraform-aws-eks-flux's application_target, as a cluster root exports it
  cluster = {
    name              = "patchy-x"
    namespace         = "flux-system"
    platform_registry = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform"
    tree              = "aws"
    issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
    keyed             = false
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/ABC"
    oidc_issuer       = "oidc.eks.eu-west-2.amazonaws.com/id/ABC"
    secret_prefix     = ""
  }

  domain = "patchy.bitwisemedia.co.uk"
}

run "default_election" {
  command = plan

  assert {
    condition     = sort(keys(aws_secretsmanager_secret.main)) == tolist(["patchy-anthropic-token", "patchy-github-app-id", "patchy-github-app-private-key", "patchy-webhook-secret"])
    error_message = "the default election (claude on anthropic) must create exactly the GitHub App trio plus the anthropic token"
  }

  assert {
    condition     = aws_secretsmanager_secret.main["patchy-github-app-id"].name == "patchy-github-app-id"
    error_message = "an empty cluster.secret_prefix must keep the unprefixed secret names"
  }

  assert {
    condition     = toset(local.secret_readers) == toset([{ namespace = "patchy", service_account = "patchy-secrets" }])
    error_message = "the brokered claude harness mounts no credential into agent pods: only the patchy-namespace reader may exist by default"
  }

  assert {
    condition     = length(local.workload_grants) == 0
    error_message = "the anthropic provider needs no cloud grant"
  }
}

run "application_seed" {
  command = plan

  assert {
    condition     = output.release == "application-patchy"
    error_message = "the seed is release application-patchy, the name the image's flux/ objects are adopted from"
  }

  assert {
    condition     = module.application.tag_provider == "ECRArtifactTag" && module.application.oci_provider == "aws"
    error_message = "the image lives beneath the platform registry, so its tags are listed through the ECR API and pulled as provider aws"
  }

  assert {
    condition     = module.application.path == "./deploy/aws"
    error_message = "the seed applies the image's aws tree"
  }

  assert {
    condition     = module.application.namespace == "flux-system"
    error_message = "the seed and patchy-vars live in the cluster's flux namespace"
  }
}

run "vars_contract" {
  command = plan

  assert {
    condition = sort(keys(output.vars)) == tolist([
      "AGENT_EGRESS_POLICY", "AGENT_HARNESSES", "CLAUDE_ANTHROPIC_AUTH", "CLAUDE_BEDROCK_REGION",
      "CLAUDE_BEDROCK_REGION_PREFIX", "CLAUDE_MODEL_MAP", "CLAUDE_PROVIDER", "PATCHY_DOMAIN",
      "PATCHY_EVALUATION", "PATCHY_MANIFESTS_SEMVER", "SIGNED_IDENTITY_PATCHY_MANIFESTS",
    ])
    error_message = "the patchy-vars key set is the manifests contract (tests/patchy-vars.env) and must not drift"
  }

  assert {
    condition     = output.vars.AGENT_HARNESSES == "claude" && output.vars.AGENT_EGRESS_POLICY == "cilium"
    error_message = "the default harness election must publish claude alone, with the egress dialect pinned to cilium"
  }

  assert {
    condition     = output.vars.CLAUDE_PROVIDER == "anthropic" && output.vars.CLAUDE_ANTHROPIC_AUTH == "token"
    error_message = "the claude provider must default to first-party anthropic with OAuth-token auth"
  }

  assert {
    condition = alltrue([
      for key in ["CLAUDE_BEDROCK_REGION", "CLAUDE_BEDROCK_REGION_PREFIX", "CLAUDE_MODEL_MAP"] :
      output.vars[key] == ""
    ])
    error_message = "provider knobs that do not apply must publish empty strings, not null"
  }

  assert {
    condition     = output.vars.PATCHY_EVALUATION == "false" && output.vars.PATCHY_DOMAIN == "patchy.bitwisemedia.co.uk"
    error_message = "the evaluation toggle publishes the literal false and the served host passes through"
  }

  assert {
    condition     = output.vars.PATCHY_MANIFESTS_SEMVER == "<1.0.0 >=0.1.0" && output.vars.SIGNED_IDENTITY_PATCHY_MANIFESTS == var.signed_identity_subject
    error_message = "the image's own provider and OCIRepository must read the same range and subject the seed was created with"
  }
}

run "extra_vars_merge" {
  command = plan

  variables {
    extra_vars = { PATCHY_SEMVER = "<1.0.0 >=0.4.0", AGENT_EGRESS_BROAD = "true" }
  }

  assert {
    condition     = output.vars.PATCHY_SEMVER == "<1.0.0 >=0.4.0" && output.vars.AGENT_EGRESS_BROAD == "true" && output.vars.AGENT_HARNESSES == "claude"
    error_message = "caller extras ride patchy-vars beside the module's own keys"
  }
}

run "extra_vars_cannot_shadow" {
  command = plan

  variables {
    extra_vars = { CLAUDE_PROVIDER = "bedrock" }
  }

  expect_failures = [var.extra_vars]
}

run "bedrock_provider" {
  command = plan

  variables {
    claude = {
      provider = "bedrock"
      model_map = {
        "anthropic/claude-opus-5"   = "us.anthropic.claude-opus-5"
        "anthropic/claude-sonnet-5" = "us.anthropic.claude-sonnet-5"
      }
    }
  }

  assert {
    condition     = !contains(keys(aws_secretsmanager_secret.main), "patchy-anthropic-token")
    error_message = "a bedrock cluster's broker authenticates with its Pod Identity: no anthropic secret may exist for a sync to wedge on"
  }

  assert {
    condition     = length(local.workload_grants) == 1 && contains(keys(local.workload_grants), "patchy-egress-broker")
    error_message = "the bedrock provider must hand modules/application exactly one grant, patchy-egress-broker (role <cluster>-patchy-egress-broker)"
  }

  assert {
    condition     = local.workload_grants["patchy-egress-broker"].namespace == "patchy" && local.workload_grants["patchy-egress-broker"].service_account == "patchy-egress-broker"
    error_message = "the bedrock provider must bind the broker's invoke policy to patchy/patchy-egress-broker"
  }

  assert {
    condition     = output.vars.CLAUDE_BEDROCK_REGION == "eu-west-2"
    error_message = "an unset bedrock_region must fall back to the provider's region, never an empty string"
  }

  assert {
    condition     = output.vars.CLAUDE_MODEL_MAP == "anthropic/claude-opus-5=us.anthropic.claude-opus-5,anthropic/claude-sonnet-5=us.anthropic.claude-sonnet-5"
    error_message = "the model map arrives as comma-joined sorted canonical=providerID pairs"
  }
}

run "harness_election" {
  command = plan

  variables {
    harnesses = ["copilot", "claude", "codex"]
  }

  assert {
    condition = alltrue([
      for name in ["patchy-openai-token", "patchy-copilot-token"] :
      contains(keys(aws_secretsmanager_secret.main), name)
    ])
    error_message = "the codex and copilot harnesses must each bring their credential secret"
  }

  assert {
    condition     = contains(local.secret_readers, { namespace = "patchy-agents", service_account = "patchy-secrets" })
    error_message = "a non-brokered harness mounts its credential into agent pods, so its election must derive the agent-namespace reader"
  }

  assert {
    condition     = output.vars.AGENT_HARNESSES == "claude,codex,copilot"
    error_message = "the harness election must publish sorted and comma-joined"
  }
}

run "harness_election_empty" {
  command = plan

  variables {
    harnesses = []
  }

  assert {
    condition     = output.vars.AGENT_HARNESSES == "none"
    error_message = "an empty election must publish the reserved name none - an empty string would re-trigger the manifests' claude := default"
  }

  assert {
    condition     = sort(keys(aws_secretsmanager_secret.main)) == tolist(["patchy-github-app-id", "patchy-github-app-private-key", "patchy-webhook-secret"])
    error_message = "with no harness only the GitHub App trio remains"
  }
}

run "cluster_secret_prefix" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform"
      tree              = "aws"
      issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
      keyed             = false
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      oidc_issuer       = "oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      secret_prefix     = "patchy-x-"
    }
  }

  assert {
    condition     = alltrue([for secret in values(aws_secretsmanager_secret.main) : startswith(secret.name, "patchy-x-")])
    error_message = "the cluster's SECRET_PREFIX must prefix every container name - the reader roles may read nothing else"
  }
}

run "sso_waits_on_dex" {
  command = plan

  variables {
    sso_enabled = true
  }

  assert {
    condition     = length([for name in keys(aws_secretsmanager_secret.main) : name if strcontains(name, "status-auth")]) == 0
    error_message = "the status server's auth config is a ConfigMap in the image, not a Secrets Manager document"
  }
}

run "keyed_cluster" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform"
      tree              = "aws"
      keyed             = true
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      oidc_issuer       = "oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      secret_prefix     = ""
    }
  }

  # modules/application refuses a keyless subject on a keyed cluster without
  # an explicit issuer; reaching a plan proves the seed switched to keyed.
  assert {
    condition     = output.release == "application-patchy"
    error_message = "a KMS-keyed cluster must seed patchy verified against the cosign-pub Secret"
  }
}

run "evaluation_publishes_the_election" {
  command = plan

  variables {
    sso_enabled = true
    evaluation  = { enabled = true }
  }

  assert {
    condition     = output.vars.PATCHY_EVALUATION == "true"
    error_message = "enabling the evaluation controller must publish PATCHY_EVALUATION as the literal true"
  }
}

run "evaluation_requires_sso" {
  command = plan

  variables {
    evaluation = { enabled = true }
  }

  expect_failures = [var.evaluation]
}

run "evaluation_requires_a_harness" {
  command = plan

  variables {
    sso_enabled = true
    harnesses   = []
    evaluation  = { enabled = true }
  }

  expect_failures = [var.evaluation]
}

run "bedrock_knobs_need_bedrock" {
  command = plan

  variables {
    claude = { bedrock_region = "us-east-1" }
  }

  expect_failures = [var.claude]
}

run "foreign_registry_rejected" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "ghcr.io/bitwise-media-group"
      tree              = "aws"
      issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
      keyed             = false
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      oidc_issuer       = "oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      secret_prefix     = ""
    }
  }

  expect_failures = [var.cluster]
}
