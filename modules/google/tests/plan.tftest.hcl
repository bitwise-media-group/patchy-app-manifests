# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked google and helm providers. The google
# module mirrors modules/aws, so these assert the mirror holds: the same
# seed, the same patchy-vars keys but for the provider pair, plus the
# resource-side accessor grants aws does not need.

mock_provider "google" {}

mock_provider "helm" {}

variables {
  # terraform-google-gke-flux's application_target, as a cluster root exports it
  cluster = {
    name              = "patchy-x"
    namespace         = "flux-system"
    platform_registry = "us-central1-docker.pkg.dev/ci-test-project/platform"
    tree              = "google"
    issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
    keyed             = false
    project           = "ci-test-project"
    project_number    = "111111111111"
    workload_pool     = "ci-test-project.svc.id.goog"
    secret_prefix     = ""
  }

  domain = "patchy.bitwisemedia.co.uk"
}

run "default_election" {
  command = plan

  assert {
    condition     = sort(keys(google_secret_manager_secret.main)) == tolist(["patchy-anthropic-token", "patchy-github-app-id", "patchy-github-app-private-key", "patchy-webhook-secret"])
    error_message = "the default election (claude on anthropic) must create exactly the GitHub App trio plus the anthropic token"
  }

  assert {
    condition     = alltrue([for secret in values(google_secret_manager_secret.main) : secret.project == "ci-test-project"])
    error_message = "the containers live in the cluster's project, where GKE's secret sync reads them"
  }

  assert {
    condition = alltrue([
      for name, member in google_secret_manager_secret_iam_member.sync :
      member.role == "roles/secretmanager.secretAccessor"
      && member.member == "principal://iam.googleapis.com/projects/111111111111/locations/global/workloadIdentityPools/ci-test-project.svc.id.goog/subject/ns/patchy/sa/patchy-secrets"
    ])
    error_message = "every default container is read by the patchy-namespace sync KSA as a federated principal in the cluster's pool"
  }

  assert {
    condition     = length(local.workload_grants) == 0 && output.vars.CLAUDE_VERTEX_PROJECT_ID == ""
    error_message = "the anthropic provider needs no cloud grant and publishes an empty vertex project"
  }
}

run "application_seed" {
  command = plan

  assert {
    condition     = output.release == "application-patchy"
    error_message = "the seed is release application-patchy, the name the image's flux/ objects are adopted from"
  }

  assert {
    condition     = module.application.tag_provider == "GARArtifactTag" && module.application.oci_provider == "gcp"
    error_message = "the image lives beneath the platform registry, so its tags are listed through the Artifact Registry API and pulled as provider gcp"
  }

  assert {
    condition     = module.application.path == "./deploy/google"
    error_message = "the seed applies the image's google tree"
  }
}

run "vars_mirror_aws" {
  command = plan

  assert {
    condition = sort(keys(output.vars)) == tolist([
      "AGENT_EGRESS_POLICY", "AGENT_HARNESSES", "CLAUDE_ANTHROPIC_AUTH", "CLAUDE_MODEL_MAP", "CLAUDE_PROVIDER",
      "CLAUDE_VERTEX_PROJECT_ID", "CLAUDE_VERTEX_REGION", "PATCHY_DOMAIN", "PATCHY_EVALUATION",
      "PATCHY_MANIFESTS_SEMVER", "SIGNED_IDENTITY_PATCHY_MANIFESTS",
    ])
    error_message = "the patchy-vars key set mirrors modules/aws with the vertex pair in place of the bedrock pair"
  }

  assert {
    condition     = output.vars.AGENT_EGRESS_POLICY == "auto"
    error_message = "on GKE the egress dialect defaults to the chart's probe"
  }
}

run "extra_vars_merge" {
  command = plan

  variables {
    extra_vars = { SCC_PUSH_AUDIENCE = "https://integrations.patchy.bitwisemedia.co.uk" }
  }

  assert {
    condition     = output.vars.SCC_PUSH_AUDIENCE == "https://integrations.patchy.bitwisemedia.co.uk" && output.vars.AGENT_HARNESSES == "claude"
    error_message = "caller extras ride patchy-vars beside the module's own keys"
  }
}

run "extra_vars_cannot_shadow" {
  command = plan

  variables {
    extra_vars = { PATCHY_DOMAIN = "elsewhere.example.com" }
  }

  expect_failures = [var.extra_vars]
}

run "vertex_provider" {
  command = plan

  variables {
    claude = {
      provider          = "vertex"
      vertex_region     = "us-east5"
      vertex_project_id = "ci-test-models"
    }
  }

  assert {
    condition     = !contains(keys(google_secret_manager_secret.main), "patchy-anthropic-token")
    error_message = "a vertex cluster's broker authenticates with its Workload Identity: no anthropic secret may exist"
  }

  assert {
    condition     = local.workload_grants["patchy-egress-broker"].project == "ci-test-models" && local.workload_grants["patchy-egress-broker"].roles[0] == "roles/aiplatform.user"
    error_message = "the vertex provider must grant the broker aiplatform.user in the serving project"
  }

  assert {
    condition     = endswith(output.workload_members["patchy-egress-broker"], "/subject/ns/patchy/sa/patchy-egress-broker")
    error_message = "the grant binds the broker's KSA as a direct federated principal"
  }

  assert {
    condition     = output.vars.CLAUDE_VERTEX_REGION == "us-east5" && output.vars.CLAUDE_VERTEX_PROJECT_ID == "ci-test-models"
    error_message = "the vertex pair must publish the configured region and project"
  }
}

run "vertex_project_defaults_to_cluster" {
  command = plan

  variables {
    claude = { provider = "vertex" }
  }

  assert {
    condition     = local.workload_grants["patchy-egress-broker"].project == "ci-test-project" && output.vars.CLAUDE_VERTEX_PROJECT_ID == "ci-test-project"
    error_message = "an unset vertex_project_id serves from the cluster's project"
  }
}

run "agent_namespace_readers" {
  command = plan

  variables {
    harnesses = ["claude", "codex"]
  }

  assert {
    condition     = endswith(google_secret_manager_secret_iam_member.sync["patchy-openai-token"].member, "/ns/patchy-agents/sa/patchy-secrets")
    error_message = "a non-brokered harness's credential is read by the agent-namespace sync KSA"
  }
}

run "cluster_secret_prefix" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "us-central1-docker.pkg.dev/ci-test-project/platform"
      tree              = "google"
      issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
      keyed             = false
      project           = "ci-test-project"
      project_number    = "111111111111"
      workload_pool     = "ci-test-project.svc.id.goog"
      secret_prefix     = "patchy-x-"
    }
  }

  assert {
    condition     = alltrue([for secret in values(google_secret_manager_secret.main) : startswith(secret.secret_id, "patchy-x-")])
    error_message = "the cluster's SECRET_PREFIX must prefix every container id - the manifests sync <prefix><name>"
  }
}

run "sso_waits_on_dex" {
  command = plan

  variables {
    sso_enabled = true
    evaluation  = { enabled = true }
  }

  assert {
    condition     = length([for name in keys(google_secret_manager_secret.main) : name if strcontains(name, "status-auth")]) == 0
    error_message = "the status server's auth config is a ConfigMap in the image, not a Secret Manager document"
  }

  assert {
    condition     = output.vars.PATCHY_EVALUATION == "true"
    error_message = "enabling the evaluation controller must publish PATCHY_EVALUATION as the literal true"
  }
}

run "keyed_cluster" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "us-central1-docker.pkg.dev/ci-test-project/platform"
      tree              = "google"
      keyed             = true
      project           = "ci-test-project"
      project_number    = "111111111111"
      workload_pool     = "ci-test-project.svc.id.goog"
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

run "evaluation_requires_sso" {
  command = plan

  variables {
    evaluation = { enabled = true }
  }

  expect_failures = [var.evaluation]
}

run "foreign_registry_rejected" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "ghcr.io/bitwise-media-group"
      tree              = "google"
      issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
      keyed             = false
      project           = "ci-test-project"
      project_number    = "111111111111"
      workload_pool     = "ci-test-project.svc.id.goog"
      secret_prefix     = ""
    }
  }

  expect_failures = [var.cluster]
}
