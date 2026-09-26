#!/usr/bin/env bash
# Runs before `terraform destroy` removes the nodes (null_resource.flux_pre_destroy, hcloud and kind).
# While the cluster is still alive, let it clean up what Terraform does not know about:
#   1. suspend Flux, so it does not recreate what we delete - but keep its controllers running: they
#      remove their own finalizers (HelmRelease, ImagePolicy, ...) when those objects are deleted;
#      stop Kyverno and remove all admission webhooks - teardown needs none, and a webhook without a
#      running backend (failurePolicy Fail) blocks every delete in the namespaces;
#   2. delete the target namespaces except flux-system - with them go the workloads, CNPG clusters
#      and their PVCs, so no controller recreates a PVC; then every other PVC in the cluster;
#   3. wait until the PersistentVolumes are gone - volumes with reclaimPolicy Delete (hcloud-volumes)
#      are removed by the CSI driver only while it runs; after the nodes are gone they stay, billed;
#   4. wait for those namespaces; only for what is still stuck, clear the finalizers on the objects
#      that actually have them (not every object - that took hundreds of API calls per namespace);
#   5. only then remove Flux itself: the FluxInstance (the operator uninstalls the controllers) and
#      the flux-system namespace. Removing Flux first left every Flux object's finalizer unprocessed.
# Everything left over is reported loudly. Terraform continues either way (on_failure = continue),
# so the log lines here are the only warning.

set -o errexit
set -o nounset
set -o pipefail

KUBECONFIG_PATH="${1:-}"
TARGET_NAMESPACES_CSV="${2:-flux-system,develop,staging,production,observability}"
PV_TIMEOUT="${PRE_DESTROY_PV_TIMEOUT:-300}"
NS_TIMEOUT="${PRE_DESTROY_NS_TIMEOUT:-180}"

log() {
  echo "[flux-pre-destroy] $*"
}

warn() {
  echo "[flux-pre-destroy] WARNING: $*" >&2
}

kc() {
  kubectl --kubeconfig="${KUBECONFIG_PATH}" --request-timeout=30s "$@"
}

api_exists() {
  kc api-resources -o name 2>/dev/null | grep -qx "$1"
}

# Wait until "$@" (a kubectl get ... -o name) succeeds AND prints nothing, or the timeout (seconds)
# passes. A failed call (API unreachable) is not "empty" - keep waiting.
wait_until_empty() {
  local timeout="$1"
  shift
  local deadline=$((SECONDS + timeout))
  local out
  while (( SECONDS < deadline )); do
    if out=$(kc "$@" 2>/dev/null) && [[ -z "${out}" ]]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

suspend_flux() {
  local resource
  log "suspending Flux reconciliation"
  for resource in \
    kustomizations.kustomize.toolkit.fluxcd.io \
    helmreleases.helm.toolkit.fluxcd.io \
    imageupdateautomations.image.toolkit.fluxcd.io
  do
    api_exists "${resource}" || continue
    kc get "${resource}" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | while read -r ns name; do
          [[ -z "${name}" ]] && continue
          kc -n "${ns}" patch "${resource}" "${name}" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
        done
  done
}

# Last: the FluxInstance (flux-operator uninstalls the controllers on its deletion), then flux-system.
remove_flux() {
  if api_exists fluxinstances.fluxcd.controlplane.io; then
    log "removing the FluxInstance"
    kc -n flux-system delete fluxinstance flux --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    wait_until_empty 120 -n flux-system get fluxinstances -o name \
      || warn "FluxInstance still present after 120s - its finalizer is cleared with the namespace"
  fi
  delete_namespaces flux-system
  wait_for_namespaces flux-system
}

remove_admission_webhooks() {
  # Kyverno re-registers its webhooks while it runs - stop it first.
  if kc get namespace kyverno >/dev/null 2>&1; then
    log "stopping Kyverno"
    kc -n kyverno scale deployment --all --replicas=0 >/dev/null 2>&1 || true
  fi
  log "removing admission webhooks"
  kc delete validatingwebhookconfigurations,mutatingwebhookconfigurations --all >/dev/null 2>&1 || true
}

delete_volumes() {
  log "deleting the remaining PersistentVolumeClaims (the CSI driver removes their volumes)"
  kc delete pvc --all -A --wait=false >/dev/null 2>&1 || true
  if wait_until_empty "${PV_TIMEOUT}" get pv -o name; then
    log "all PersistentVolumes deleted"
  else
    warn "PersistentVolumes still present after ${PV_TIMEOUT}s - their volumes will outlive the cluster (billed):"
    kc get pv -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase,CLAIM:.spec.claimRef.name >&2 || true
  fi
}

delete_namespaces() {  # namespace...
  local ns
  for ns in "$@"; do
    log "deleting namespace ${ns}"
    kc delete namespace "${ns}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  done
}

wait_for_namespaces() {  # namespace...
  local ns
  if wait_until_empty "${NS_TIMEOUT}" get namespace "$@" -o name --ignore-not-found=true; then
    log "namespaces deleted: $*"
    return 0
  fi
  for ns in "$@"; do
    kc get namespace "${ns}" >/dev/null 2>&1 || continue
    unblock_namespace "${ns}"
  done
}

# Last resort for a namespace stuck in Terminating: clear finalizers only on the objects that still
# have any (one list per resource type), then the namespace's own spec.finalizers.
unblock_namespace() {
  local ns="$1"
  local resource object
  warn "namespace ${ns} still terminating after ${NS_TIMEOUT}s - clearing the finalizers that block it"
  while read -r resource; do
    [[ -z "${resource}" || "${resource}" == events* ]] && continue
    kc -n "${ns}" get "${resource}" -o jsonpath='{range .items[?(@.metadata.finalizers)]}{.kind}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | while read -r object; do
          [[ -z "${object}" ]] && continue
          log "  clearing finalizers on ${ns}/${object}"
          kc -n "${ns}" patch "${resource}" "${object#*/}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        done
  done < <(kc api-resources --verbs=list --namespaced -o name 2>/dev/null || true)
  # Clearing the object finalizers often lets the namespace finish on its own.
  sleep 5
  if [[ -z "$(kc get namespace "${ns}" --ignore-not-found -o name 2>/dev/null)" ]]; then
    log "namespace ${ns} deleted"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found - cannot clear spec.finalizers of namespace ${ns}"
    return 0
  fi
  if ! kc get namespace "${ns}" -o json \
    | jq '.spec.finalizers = []' \
    | kc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null; then
    warn "could not clear spec.finalizers of namespace ${ns} - it may stay Terminating"
  fi
}

if ! command -v kubectl >/dev/null 2>&1; then
  warn "kubectl not found - no cluster-side cleanup; volumes created by the cluster may be left behind"
  exit 0
fi
if [[ -z "${KUBECONFIG_PATH}" || ! -f "${KUBECONFIG_PATH}" ]]; then
  warn "kubeconfig '${KUBECONFIG_PATH}' not found - no cluster-side cleanup; volumes created by the cluster may be left behind"
  exit 0
fi
if ! kc version >/dev/null 2>&1; then
  warn "cluster not reachable - no cluster-side cleanup; volumes created by the cluster may be left behind"
  exit 0
fi

IFS=',' read -r -a requested <<< "${TARGET_NAMESPACES_CSV}"
namespaces=()
# "not there" only when the API says so; an API error is retried, and a namespace that still cannot
# be checked is kept - deleting a namespace that is already gone is harmless, skipping one is not.
namespace_state() {  # prints: present | absent | unknown
  local out
  for _ in 1 2 3; do
    if out=$(kc get namespace "$1" --ignore-not-found -o name 2>/dev/null); then
      [[ -n "${out}" ]] && echo present || echo absent
      return 0
    fi
    sleep 5
  done
  echo unknown
}
for ns in "${requested[@]}"; do
  [[ -z "${ns}" ]] && continue
  case "$(namespace_state "${ns}")" in
    present) namespaces+=("${ns}") ;;
    unknown) warn "could not check namespace ${ns} after 3 tries - deleting it anyway"; namespaces+=("${ns}") ;;
  esac
done

# flux-system is removed last (remove_flux), after everything its controllers have to clean up.
app_namespaces=()
flux_namespace=false
for ns in ${namespaces[@]+"${namespaces[@]}"}; do
  if [[ "${ns}" == flux-system ]]; then flux_namespace=true; else app_namespaces+=("${ns}"); fi
done

suspend_flux
remove_admission_webhooks
if (( ${#app_namespaces[@]} > 0 )); then
  delete_namespaces "${app_namespaces[@]}"
fi
delete_volumes
if (( ${#app_namespaces[@]} > 0 )); then
  wait_for_namespaces "${app_namespaces[@]}"
fi
if [[ "${flux_namespace}" == true ]]; then
  remove_flux
fi

log "pre-destroy cleanup finished"
