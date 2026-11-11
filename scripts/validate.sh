#!/usr/bin/env bash
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Render and validate everything a cluster would apply from this image, once
# per deploy tree and signing mode ({aws,google} x {keyless,keyed}):
#   1. kustomize-build the deploy tree (common + flux + the cloud overlay)
#   2. substitute cluster-vars AND patchy-vars the way the seeded
#      Kustomization does (postBuild.substituteFrom), faithfully to the
#      controller's roundtrip - so an empty var that would become null on a
#      cluster becomes null (and fails) here, and a var neither ConfigMap
#      publishes fails strict substitution (the toolchain's
#      flux-substitute.sh)
#   3. render every ResourceSet with sample inputs (flux-operator CLI)
#   4. kubeconform the results against Flux + flux-operator + CRD schemas
#      (the toolchain's kubeconform.sh)
# plus the seed-contract guard: the flux/ objects must carry exactly the
# names, namespace and prune label the modules/application seed creates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"
# The containers archetype's Flux helpers: postBuild substitution with the
# strict check and null guard, and kubeconform with the house schema catalog.
HELPERS="$ROOT/.mise/archetypes/containers/scripts"
rm -rf "$BUILD" && mkdir -p "$BUILD"

command -v kustomize >/dev/null || { echo "kustomize not found" >&2; exit 1; }
command -v kubeconform >/dev/null || { echo "kubeconform not found" >&2; exit 1; }
command -v flux-operator >/dev/null || { echo "flux-operator CLI not found" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq not found" >&2; exit 1; }

# Substitute vars the way kustomize-controller's postBuild does on a real
# cluster: strict (a bare ${VAR} that neither ConfigMap publishes fails, as it
# would fail the Kustomization), through the controller's
# parse/re-serialize/substitute/re-parse round trip, then the null guard (no
# ${VAR}-bearing scalar may substitute to null -- gate the key absent, use
# << "${VAR:=}" | quote >>, or move it into a resourcesTemplate block). Each
# tree's pass runs under only that cloud's env plus patchy-vars.
substitute() { # substitute <in-file> <out-file>
  "$HELPERS/flux-substitute.sh" "$1" "$2"
}

# The seed contract: modules/application creates a ResourceSetInputProvider
# and a ResourceSet named patchy-manifests in flux-system, and the
# ResourceSet emits Kustomization/patchy; this image ships the same objects
# so the Kustomization adopts them. A drift here is silent on a cluster
# (two providers, two Kustomizations, an orphaned seed), so it is asserted.
check_seed_contract() {
  local built="$1" kinds
  kinds="$(yq 'select(.kind == "ResourceSetInputProvider" or .kind == "ResourceSet") | select(.metadata.namespace == "flux-system") | .kind + "/" + .metadata.name + "@" + (.metadata.labels["kustomize.toolkit.fluxcd.io/prune"] // "prunable")' "$built" | grep -v '^---$' | sort | tr '\n' ' ')"
  [[ "$kinds" == "ResourceSet/patchy-manifests@disabled ResourceSetInputProvider/patchy-manifests@disabled " ]] \
    || { echo "seed contract: flux-system must carry exactly RSIP + ResourceSet patchy-manifests, both prune-disabled; got: $kinds" >&2; exit 1; }
  yq 'select(.kind == "ResourceSet" and .metadata.name == "patchy-manifests") | .spec.resourcesTemplate' "$built" \
    | grep -q '^  name: patchy$' \
    || { echo "seed contract: ResourceSet/patchy-manifests must emit Kustomization/patchy" >&2; exit 1; }
}

# Every ResourceSet-bearing source file needs a fixture at
# tests/inputs/<flux|common|tree>/<file>[.<variant>].yaml; each variant
# renders the same ResourceSet with a different input set.
render_resourcesets() { # render_resourcesets <tree> <out-dir>
  local tree="$1" out="$2" src scope file inputs variant vbase
  for src in "$ROOT/manifests/flux"/*.yaml "$ROOT/manifests/deploy/common"/*.yaml "$ROOT/manifests/deploy/$tree"/*.yaml; do
    grep -q '^kind: ResourceSet$' "$src" || continue
    scope="$(basename "$(dirname "$src")")"
    file="$(basename "$src" .yaml)"
    substitute "$src" "$out/src-$scope-$file.yaml"
    yq 'select(.kind == "ResourceSet")' "$out/src-$scope-$file.yaml" > "$out/rs-$scope-$file.yaml"
    [[ -f "$ROOT/tests/inputs/$scope/$file.yaml" ]] || { echo "missing test inputs tests/inputs/$scope/$file.yaml for $src" >&2; exit 1; }
    for inputs in "$ROOT/tests/inputs/$scope/$file"*.yaml; do
      vbase="$(basename "$inputs" .yaml)"
      [[ "$vbase" =~ ^${file}(\.[A-Za-z0-9-]+)?$ ]] || continue
      variant="$vbase"
      if ! flux-operator build resourceset -f "$out/rs-$scope-$file.yaml" --inputs-from "$inputs" \
        > "$out/rendered-$scope-$variant.yaml" 2> "$out/rendered-$scope-$variant.err"; then
        grep -q "no objects were generated" "$out/rendered-$scope-$variant.err" \
          || { cat "$out/rendered-$scope-$variant.err" >&2; exit 1; }
        : > "$out/rendered-$scope-$variant.yaml"
      fi
      rm -f "$out/rendered-$scope-$variant.err"
    done
  done
}

run_pass() { # run_pass <tree> <mode>
  local tree="$1" mode="$2" out
  out="$BUILD/$tree-$mode"
  mkdir -p "$out"
  echo ">> [$tree/$mode] building deploy/$tree"
  kustomize build "$ROOT/manifests/deploy/$tree" > "$out/raw.yaml"
  substitute "$out/raw.yaml" "$out/deploy.yaml"
  check_seed_contract "$out/deploy.yaml"
  echo ">> [$tree/$mode] rendering resourcesets with sample inputs"
  render_resourcesets "$tree" "$out"
}

# The null guard is the regression fence for a bug class local rendering
# used to hide; prove it still fires before trusting a green run.
echo ">> null-guard self-test"
"$HELPERS/flux-substitute.sh" --self-test

for tree in aws google; do
  for mode in keyless keyed; do
    # Each pass runs in a subshell so one cloud's env can never leak into
    # the other's render - absence of the other cloud's vars is part of
    # what is being tested.
    (
      set -a
      # shellcheck disable=SC1090
      source "$ROOT/tests/$tree.env"
      # shellcheck disable=SC1091
      source "$ROOT/tests/patchy-vars.env"
      if [[ -f "$ROOT/tests/patchy-vars.$tree.env" ]]; then
        # shellcheck disable=SC1090
        source "$ROOT/tests/patchy-vars.$tree.env"
      fi
      if [[ "$mode" == "keyed" ]]; then
        # shellcheck disable=SC1090
        source "$ROOT/tests/$tree.keyed.env"
      fi
      set +a
      run_pass "$tree" "$mode"
    )
  done
done

echo ">> kubeconform"
# CRD schemas are vendored under tests/schemas (converted from upstream CRDs);
# refresh with: curl <crd-yaml> | yq -o=json '.spec.versions[0].schema.openAPIV3Schema'
# Nothing is skipped (KUBECONFORM_SKIP empty): this image ships no CRDs.
KUBECONFORM_SCHEMAS="$ROOT/tests/schemas" KUBECONFORM_SKIP="" "$HELPERS/kubeconform.sh" \
  "$BUILD"/*/deploy.yaml "$BUILD"/*/rendered-*.yaml

echo ">> validation clean"
