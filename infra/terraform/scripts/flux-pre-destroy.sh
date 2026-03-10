#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

KUBECONFIG_PATH="${1:-}"
TARGET_NAMESPACES_CSV="${2:-flux-system,develop,staging,production,observability}"

if [[ -z "${KUBECONFIG_PATH}" ]]; then
  echo "[flux-pre-destroy] missing kubeconfig path" >&2
  exit 1
fi

log() {
  echo "[flux-pre-destroy] $*"
}

kc() {
  kubectl --kubeconfig="${KUBECONFIG_PATH}" "$@"
}

api_exists() {
  local resource="$1"
  kc api-resources -o name 2>/dev/null | grep -qx "${resource}"
}

patch_finalizers() {
  local name="$1"
  shift
  kc "$@" patch "${name}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
}

# Namespace deletion blockers live in spec.finalizers, not metadata.finalizers.
# The only way to clear them is to PUT the finalize subresource via the API.
force_delete_namespace() {
  local ns="$1"
  log "force-clearing spec.finalizers on namespace ${ns}"
  kc get namespace "${ns}" -o json \
    | jq '.spec.finalizers = []' \
    | kc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
}

delete_all_if_present() {
  local resource="$1"
  shift || true
  if api_exists "${resource}"; then
    kc "$@" delete "${resource}" --all --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  fi
}

strip_resource_finalizers_in_namespace() {
  local namespace="$1"
  local resource
  local object

  while IFS= read -r resource; do
    [[ -z "${resource}" ]] && continue
    while IFS= read -r object; do
      [[ -z "${object}" ]] && continue
      patch_finalizers "${object}" -n "${namespace}"
    done < <(kc -n "${namespace}" get "${resource}" -o name --ignore-not-found=true 2>/dev/null || true)
  done < <(kc api-resources --verbs=list --namespaced -o name 2>/dev/null || true)
}

delete_flux_inventory() {
  local flux_ns="flux-system"

  log "suspending Flux reconciliation"
  for resource in \
    "kustomizations.kustomize.toolkit.fluxcd.io" \
    "helmreleases.helm.toolkit.fluxcd.io" \
    "imageupdateautomations.image.toolkit.fluxcd.io"
  do
    if api_exists "${resource}"; then
      while IFS= read -r object; do
        [[ -z "${object}" ]] && continue
        kc -n "${flux_ns}" patch "${object}" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
      done < <(kc -n "${flux_ns}" get "${resource}" -o name --ignore-not-found=true 2>/dev/null || true)
    fi
  done

  log "deleting Flux custom resources"
  for resource in \
    "helmreleases.helm.toolkit.fluxcd.io" \
    "kustomizations.kustomize.toolkit.fluxcd.io" \
    "helmcharts.source.toolkit.fluxcd.io" \
    "helmrepositories.source.toolkit.fluxcd.io" \
    "gitrepositories.source.toolkit.fluxcd.io" \
    "ocirepositories.source.toolkit.fluxcd.io" \
    "buckets.source.toolkit.fluxcd.io" \
    "imagerepositories.image.toolkit.fluxcd.io" \
    "imagepolicies.image.toolkit.fluxcd.io" \
    "imageupdateautomations.image.toolkit.fluxcd.io" \
    "alerts.notification.toolkit.fluxcd.io" \
    "providers.notification.toolkit.fluxcd.io" \
    "receivers.notification.toolkit.fluxcd.io"
  do
    delete_all_if_present "${resource}" -n "${flux_ns}"
  done

  if api_exists "fluxinstances.fluxcd.controlplane.io"; then
    kc -n "${flux_ns}" delete fluxinstance flux --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  fi

  sleep 5

  log "clearing remaining Flux finalizers"
  strip_resource_finalizers_in_namespace "${flux_ns}"
}

delete_target_namespaces() {
  IFS=',' read -r -a namespaces <<< "${TARGET_NAMESPACES_CSV}"
  local namespace
  local deadline

  for namespace in "${namespaces[@]}"; do
    [[ -z "${namespace}" ]] && continue
    kc get namespace "${namespace}" >/dev/null 2>&1 || continue
    log "clearing namespaced finalizers in ${namespace}"
    strip_resource_finalizers_in_namespace "${namespace}"
    log "deleting namespace ${namespace}"
    kc delete namespace "${namespace}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  done

  deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    local remaining=0
    for namespace in "${namespaces[@]}"; do
      [[ -z "${namespace}" ]] && continue
      if kc get namespace "${namespace}" >/dev/null 2>&1; then
        remaining=1
      fi
    done
    if [[ "${remaining}" -eq 0 ]]; then
      log "target namespaces deleted"
      return 0
    fi
    sleep 3
  done

  log "forcing namespace finalizer cleanup for stuck namespaces"
  for namespace in "${namespaces[@]}"; do
    [[ -z "${namespace}" ]] && continue
    if kc get namespace "${namespace}" >/dev/null 2>&1; then
      force_delete_namespace "${namespace}"
    fi
  done
}

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl not found; skipping Flux pre-destroy cleanup"
  exit 0
fi

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  log "kubeconfig ${KUBECONFIG_PATH} not found; skipping Flux pre-destroy cleanup"
  exit 0
fi

if ! kc version --request-timeout=5s >/dev/null 2>&1; then
  log "cluster not reachable; skipping Flux pre-destroy cleanup"
  exit 0
fi

delete_flux_inventory
delete_target_namespaces

log "pre-destroy cleanup finished"
