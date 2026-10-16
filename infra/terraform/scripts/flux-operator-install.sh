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
# It then waits until the FluxInstance CRD is served - Terraform applies a FluxInstance right after.
#
# Usage: flux-operator-install.sh <kubeconfig> <operator version without "v", e.g. 0.61.0>
# Changes the cluster (it applies the operator's CRDs, RBAC and Deployment). Exit non-zero on any failure.
# https://fluxcd.control-plane.io/operator/
set -Eeuo pipefail

kubeconfig="${1:?usage: flux-operator-install.sh <kubeconfig> <version>}"
version="${2:?usage: flux-operator-install.sh <kubeconfig> <version>}"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "flux-operator-install: version must look like 0.61.0 (no leading v), got '${version}'" >&2
  exit 1
fi

manifest="$(mktemp)"
trap 'rm -f "${manifest}"' EXIT
curl -fsSL --retry 3 --retry-all-errors -o "${manifest}" \
  "https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v${version}/install.yaml"

kubectl --kubeconfig="${kubeconfig}" apply --server-side --field-manager=flux-operator-install \
  --force-conflicts -f "${manifest}"
kubectl --kubeconfig="${kubeconfig}" wait --for=condition=Established --timeout=120s \
  crd/fluxinstances.fluxcd.controlplane.io
