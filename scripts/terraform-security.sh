#!/bin/bash
# terraform-security.sh - Checkov security scan of the Terraform modules (pre-commit hook
# terraform-security, runs when a .tf or .tfvars file is staged).
#
# Checkov reads the code, not the cluster, and reports settings known to be risky (a secret in
# plain text, a network rule open to the world). It scans every module terraform-validate.sh
# validates. A finding that is a decision, not a gap, is skipped where it is made, with its reason
# (`# checkov:skip=ID:reason` inside the resource) - never here, where nobody reading the code sees it.
# Checkov is a required tool (scripts/check-tools.sh): without it the hook fails instead of
# skipping, so "every commit that touches .tf is scanned" stays true.
#
# One checkov run per module: given several -d, Checkov 3 scanned only the first directory and
# reported it once per -d - the Hetzner module and the state lab were never scanned (found 2026-10-17).
#
# CKV_TF_1 (module source by commit hash) is skipped for all: the modules come from the Terraform
# registry, which takes a version, not a commit - they are pinned to an exact version instead.
#
# Registry modules are not downloaded (Checkov warns "Failed to download module ..."): their code is the
# upstream's, pinned and read when it is bumped. With --download-external-modules Checkov reports every
# policy document a module carries, also of features turned off (34 findings in eks-pod-identity on
# 2026-10-17, none of them created), and a finding inside a module cannot be skipped where it is made.
#
# CI pins the Checkov version (.github/workflows/pre-commit.yml); a newer one can bring new checks, so a
# local run with an older Checkov can pass where CI fails.
#
# Usage: scripts/terraform-security.sh   (from the repository root). Needs checkov; changes nothing.
set -e
if ! command -v checkov &>/dev/null; then
    echo "ERROR: checkov is not installed - the Terraform security scan cannot run" >&2
    echo "Install: brew install checkov (macOS) or pip install checkov; see scripts/check-tools.sh" >&2
    exit 1
fi

failed=""
for dir in infra/terraform/kind_cluster infra/terraform/hcloud_cluster infra/terraform/gcp_foundation \
  infra/terraform/gke_cluster infra/terraform/aws_foundation infra/terraform/state-lab; do
    echo "checkov: ${dir}"
    checkov -d "${dir}" --framework terraform --quiet --compact --skip-check CKV_TF_1 || failed="${failed} ${dir}"
done
if [ -n "${failed}" ]; then
    echo "ERROR: Checkov findings in:${failed}" >&2
    exit 1
fi
