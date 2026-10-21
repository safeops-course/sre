#!/usr/bin/env bash
# Installs (or upgrades) the Flux Operator from its release manifest - one place for every cluster
# module (null_resource.flux_operator_install in gke_cluster, hcloud_cluster and kind_cluster).
#
# Server-side apply, not `kubectl apply`: on GKE and Hetzner Terraform creates flux-system before this
# runs (for the Secrets Flux reads), and a client-side apply then warns that the namespace lacks the
# last-applied-configuration annotation (seen on GKE 2026-10-16).
# --field-manager: the objects are owned by this install by name, not by any `kubectl apply`.
# --force-conflicts: this install is the owner of these objects. A cluster installed client-side before
# (kind, until 2026-10-16) takes a new operator version instead of stopping on a field conflict with
# "kubectl-client-side-apply"; its first server-side apply prints a one-time migration notice.
# The manifest is downloaded with retries first: a GitHub hiccup must not stop a billed cluster's apply.
# Then its SHA-256 must be the one pinned in Git (flux-operator.sha256 next to this script, checked against
# the release's build provenance): a changed or replaced release asset is never applied with cluster-admin rights.
# Then the operator's memory request is raised in that checked manifest, before the one apply: the release
# asks for 64Mi, the operator used 132-147Mi at rest on kind (2026-10-21), and a pod using more memory than
# it requested is among the first the kubelet evicts when the node runs short. The Flux controllers'
# requests are in flux-controllers-resources.yaml.
# Last it waits until the FluxInstance CRD is served - Terraform applies a FluxInstance right after.
#
# Needs curl, yq (v4) and kubectl.
# Usage: flux-operator-install.sh <kubeconfig> <version without "v", e.g. 0.61.0> <install.yaml SHA-256>
# Changes the cluster (it applies the operator's CRDs, RBAC and Deployment). Exit non-zero on any failure.
# https://fluxcd.control-plane.io/operator/
set -Eeuo pipefail

usage="usage: flux-operator-install.sh <kubeconfig> <version> <install.yaml sha256>"
kubeconfig="${1:?${usage}}"
version="${2:?${usage}}"
expected_sha256="${3:?${usage}}"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "flux-operator-install: version must look like 0.61.0 (no leading v), got '${version}'" >&2
  exit 1
fi

# sha256_of FILE - the file's SHA-256: sha256sum on Linux (CI), shasum on macOS.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

manifest="$(mktemp)"
trap 'rm -f "${manifest}"' EXIT
curl -fsSL --retry 3 --retry-all-errors -o "${manifest}" \
  "https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v${version}/install.yaml"

actual_sha256="$(sha256_of "${manifest}")"
if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
  echo "flux-operator-install: install.yaml of v${version} has SHA-256 ${actual_sha256}, Git pins ${expected_sha256}" >&2
  echo "  - check the release (infra/terraform/scripts/flux-operator.sha256 says how) before changing its line" >&2
  exit 1
fi

yq -i '(select(.kind == "Deployment" and .metadata.name == "flux-operator")
  | .spec.template.spec.containers[0].resources.requests.memory) = "192Mi"' "${manifest}"

kubectl --kubeconfig="${kubeconfig}" apply --server-side --field-manager=flux-operator-install \
  --force-conflicts -f "${manifest}"
kubectl --kubeconfig="${kubeconfig}" wait --for=condition=Established --timeout=120s \
  crd/fluxinstances.fluxcd.controlplane.io
