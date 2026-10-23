# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# patchy-app-manifests - patchy as a self-owned application image for the
# platform clusters: the manifests are packaged as a cosign-signed OCI
# artifact (oci://<registry>/manifests/patchy) that a cluster seeds once and
# flux owns from then on; the out-of-cluster halves (secret containers, IAM
# grants, the seed itself) are the modules/{aws,google} terraform modules,
# which install patchy onto a cluster through the cluster modules'
# modules/application.
#
# Everything lives in mise tasks: the shared toolchain submodule at .mise/
# provides the pinned tools + the common lint contract (selected in the root
# mise.toml), and tasks.toml carries the validation surface. This Makefile is
# only the thin forwarding shim - `make <task>` == `mise run <task>`.
include .mise/common/include.mk
