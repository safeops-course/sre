#!/usr/bin/env bash
# Runs before `terraform destroy` removes the nodes (terraform_data.flux_pre_destroy, hcloud, gke, eks, aks and kind).
# While the cluster is still alive, let it clean up what Terraform does not know about:
#   1. suspend Flux, so it does not recreate what we delete - but keep its controllers running: they
#      remove their own finalizers (HelmRelease, ImagePolicy, ...) when those objects are deleted;
#      stop Kyverno and remove all admission webhooks - teardown needs none, and a webhook without a
#      running backend (failurePolicy Fail) blocks every delete in the namespaces;
#      remove every PodDisruptionBudget outside kube-system - in a teardown it only makes a drain or an
#      eviction wait (GKE waits up to an hour per node pool, billed);
#      delete the Ingresses external-dns publishes and wait until it deleted their DNS records: each
#      provider has its own owner ID, so a record left behind is skipped by the next cluster for ever;
#      delete every LoadBalancer Service and wait for it: the cloud's load balancer goes only with it;
#   2. stop the CloudNativePG operator and its plugins (cnpg-system) - a running operator recreates
#      what a terminating namespace is deleting under its Cluster (ServiceAccount, RoleBinding), is
#      refused and logs an ERROR many times a second: alerts from a teardown; it keeps no finalizer on
#      its objects, so nothing waits for it. Then delete the target namespaces except flux-system -
#      with them go the workloads, CNPG clusters and their PVCs, so no controller recreates a PVC;
#      then stop their pods at once (grace period 0): CloudNativePG gives Postgres up to 30 minutes
#      to shut down, and a running pod keeps its disk attached; a terminating namespace takes no new
#      pod; then every other PVC in the cluster;
#   3. wait until the PersistentVolumes are gone - volumes with reclaimPolicy Delete (hcloud-volumes)
#      are removed by the CSI driver only while it runs; after the nodes are gone they stay, billed;
#   4. wait for those namespaces; only for what is still stuck, clear the finalizers on the objects
#      that actually have them (not every object - that took hundreds of API calls per namespace);
#   5. only then remove Flux itself: the ResourceSets and their input providers in flux-system (their
#      finalizer needs flux-operator, still running), the FluxInstance (the operator uninstalls the
#      controllers) and the flux-system namespace. Removing Flux first left every Flux object's
#      finalizer unprocessed.
# Everything left over is reported loudly. Terraform continues either way (on_failure = continue),
# so the log lines here are the only warning.
#
# Usage: flux-pre-destroy.sh <kubeconfig> [namespaces, comma-separated]
#   Called by the destroy-time provisioner of terraform_data.flux_pre_destroy in
#   infra/terraform/{hcloud_cluster,kind_cluster}/main.tf and {gke,eks,aks}_cluster/flux.tf - not meant to be run by hand.
# Needs kubectl and jq (the published Ingresses, the last-resort namespace finalize). It talks only to the cluster in
# the kubeconfig it is given (--kubeconfig), never to the current context.
# Changes the cluster: it suspends Flux, stops Kyverno and CloudNativePG, deletes the webhooks, every PodDisruptionBudget
# outside kube-system, the Ingresses external-dns publishes (and so their DNS records), the given namespaces (their pods at once), every PVC, and the ResourceSets and
# input providers in flux-system. Env: PRE_DESTROY_PV_TIMEOUT / PRE_DESTROY_NS_TIMEOUT / PRE_DESTROY_DNS_TIMEOUT
# (seconds, default 300 / 180 / 180).
# Without kubectl, the kubeconfig or a reachable cluster it warns and exits 0 - nothing to clean.

set -o errexit
set -o nounset
set -o pipefail

KUBECONFIG_PATH="${1:-}"
TARGET_NAMESPACES_CSV="${2:-flux-system,develop,staging,production,observability,traefik}"
PV_TIMEOUT="${PRE_DESTROY_PV_TIMEOUT:-300}"
LB_TIMEOUT="${PRE_DESTROY_LB_TIMEOUT:-300}"
NS_TIMEOUT="${PRE_DESTROY_NS_TIMEOUT:-180}"
DNS_TIMEOUT="${PRE_DESTROY_DNS_TIMEOUT:-180}"

# log MESSAGE / warn MESSAGE - progress on stdout, problems on stderr, both prefixed.
log() {
  echo "[flux-pre-destroy] $*"
}

warn() {
  echo "[flux-pre-destroy] WARNING: $*" >&2
}

# kc ARGS... - kubectl against the cluster being destroyed, with a timeout so a dying API cannot hang it.
kc() {
  kubectl --kubeconfig="${KUBECONFIG_PATH}" --request-timeout=30s "$@"
}

# api_exists RESOURCE - true when the cluster serves that resource type (e.g. a Flux CRD is installed).
# The list is read into a variable first, not piped into grep -q: grep -q exits at the first match,
# kubectl - still writing hundreds of lines - gets SIGPIPE, and under pipefail the pipeline fails:
# "not served" for a type that is, and its objects would be skipped before the destroy.
api_exists() {
  local served
  served="$(kc api-resources -o name 2>/dev/null)" || return 1
  grep -qxF -- "$1" <<<"${served}"
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

# suspend_flux - set spec.suspend on every Kustomization, HelmRelease and ImageUpdateAutomation,
# so Flux stops re-creating what the next steps delete (its controllers keep running).
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

# Last: the operator's own objects in flux-system, the FluxInstance (flux-operator uninstalls the
# controllers on its deletion), then flux-system. ResourceSets and ResourceSetInputProviders carry a
# finalizer that only flux-operator removes - delete them while it still runs: deleting flux-system took
# the operator with it, the three backend input providers kept the namespace terminating, and the 180 s
# fallback had to clear their finalizers (GKE cycle 2026-10-16). Only flux-system, where this repository
# puts them: deleting a ResourceSet also deletes what it generated.
remove_flux() {
  local kind kinds=()
  for kind in resourcesets.fluxcd.controlplane.io resourcesetinputproviders.fluxcd.controlplane.io; do
    api_exists "${kind}" && kinds+=("${kind}")
  done
  if ((${#kinds[@]} > 0)); then
    log "removing the ResourceSets and their input providers in flux-system while flux-operator runs"
    kc -n flux-system delete "$(IFS=,; echo "${kinds[*]}")" --all --ignore-not-found=true --wait=false >/dev/null 2>&1 \
      || warn "could not delete ${kinds[*]} in flux-system - their finalizers may keep flux-system terminating"
    if ! wait_until_empty 120 -n flux-system get "$(IFS=,; echo "${kinds[*]}")" -o name; then
      warn "still present after 120s - their finalizers are cleared with flux-system:"
      kc -n flux-system get "$(IFS=,; echo "${kinds[*]}")" -o name >&2 2>/dev/null || true
    fi
  fi
  if api_exists fluxinstances.fluxcd.controlplane.io; then
    log "removing the FluxInstance"
    kc -n flux-system delete fluxinstance flux --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    wait_until_empty 120 -n flux-system get fluxinstances -o name \
      || warn "FluxInstance still present after 120s - its finalizer is cleared with the namespace"
  fi
  delete_namespaces flux-system
  wait_for_namespaces flux-system
}

# remove_admission_webhooks - stop Kyverno and delete every admission webhook, so no webhook whose
# backend is already gone can block the deletes that follow.
remove_admission_webhooks() {
  # Kyverno re-registers its webhooks while it runs - stop it first.
  if kc get namespace kyverno >/dev/null 2>&1; then
    log "stopping Kyverno"
    kc -n kyverno scale deployment --all --replicas=0 >/dev/null 2>&1 || true
  fi
  log "removing admission webhooks"
  kc delete validatingwebhookconfigurations,mutatingwebhookconfigurations --all >/dev/null 2>&1 || true
}

# remove_disruption_budgets - delete every PodDisruptionBudget outside kube-system (the provider's own
# stay). Nothing is kept running in a teardown, and a budget at 0 allowed disruptions holds a drain:
# GKE waited for them when it deleted a node pool (2026-10-15, ~1 h billed).
remove_disruption_budgets() {
  local pdbs ns name
  pdbs="$(kc get pdb -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null)" || {
    warn "could not list PodDisruptionBudgets - a drain may wait for them"
    return 0
  }
  while read -r ns name; do
    [[ -z "${ns}" || "${ns}" == kube-system ]] && continue
    log "removing PodDisruptionBudget ${ns}/${name}"
    kc -n "${ns}" delete pdb "${name}" --ignore-not-found=true --wait=false >/dev/null 2>&1 \
      || warn "could not delete PodDisruptionBudget ${ns}/${name} - a node drain may wait for it (billed)"
  done <<<"${pdbs}"
}

# delete_load_balancers - delete every LoadBalancer Service outside kube-system and wait until they are
# gone: the cloud's service controller deletes the load balancer, its address and firewall rules only
# while the Service is there (finalizer service.kubernetes.io/load-balancer-cleanup). Done before the
# namespaces, so the namespace unblock below never has to clear that finalizer.
delete_load_balancers() {
  local lbs ns name
  lbs="$(kc get services -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null)" || {
    warn "could not list LoadBalancer Services - a cloud load balancer may outlive the cluster (billed)"
    return 0
  }
  [[ -z "${lbs//[[:space:]]/}" ]] && return 0
  while read -r ns name; do
    [[ -z "${ns}" || "${ns}" == kube-system ]] && continue
    log "deleting LoadBalancer Service ${ns}/${name} (the cloud load balancer goes with it)"
    kc -n "${ns}" delete service "${name}" --ignore-not-found=true --wait=false >/dev/null 2>&1 \
      || warn "could not delete Service ${ns}/${name} - its cloud load balancer may outlive the cluster (billed)"
  done <<<"${lbs}"
  if wait_until_empty "${LB_TIMEOUT}" get services -A --field-selector=metadata.namespace!=kube-system -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}'; then
    log "all LoadBalancer Services deleted"
  else
    warn "LoadBalancer Services still present after ${LB_TIMEOUT}s - their cloud load balancers may outlive the cluster (billed)"
  fi
}

# delete_dns_records - delete every Ingress external-dns publishes (annotation cloudflare-proxied=enabled)
# and wait until external-dns deleted their records: a DELETE line for each host (rules, TLS and the
# hostname annotation - what its ingress source publishes), then a later pass with nothing to change
# ("All records are already up to date" - a failed delete is retried and never logs that). It runs with --policy=sync and
# deletes only records with its own owner ID (one per provider); a record left behind points at a load
# balancer that is gone, and the next cluster - another owner - skips it (found 2026-10-16: dex and
# headlamp, whose namespace auth is not deleted here, kept their records). Flux is suspended, so nothing
# recreates the Ingresses. external-dns runs every minute; on a timeout the hosts left are named. It reads
# external-dns's log (text format, the chart's default) - the cluster has no Cloudflare token to ask.
delete_dns_records() {
  local ingresses hosts host start left="" found
  found="$(kc -n external-dns get deployment external-dns --ignore-not-found -o name 2>/dev/null)" || {
    warn "could not check for external-dns - DNS records not deleted; remove any left in Cloudflare by hand"
    return 0
  }
  [[ -z "${found}" ]] && { log "no external-dns on this cluster - no DNS records to delete"; return 0; }
  command -v jq >/dev/null 2>&1 || { warn "jq not found - DNS records are not deleted and may stay in Cloudflare"; return 0; }
  ingresses="$(kc get ingress -A -o json 2>/dev/null)" || { warn "could not list Ingresses - DNS records may stay in Cloudflare"; return 0; }
  hosts="$(jq -r '.items[] | select(.metadata.annotations["cloudflare-proxied"] == "enabled")
    | (.spec.rules[]?.host // empty), (.spec.tls[]?.hosts[]? // empty),
      ((.metadata.annotations["external-dns.alpha.kubernetes.io/hostname"] // "") | split(",")[] | gsub("\\s"; ""))
    | select(. != "")' <<<"${ingresses}" | sort -u)" \
    || { warn "could not read the Ingress hosts - DNS records may stay in Cloudflare"; return 0; }
  [[ -z "${hosts}" ]] && return 0
  # A minute early: the node's clock may be behind this machine's, and a DELETE line before start is missed.
  start="$(date -u -r $(( $(date +%s) - 60 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-60 seconds' +%Y-%m-%dT%H:%M:%SZ)"
  log "deleting the published Ingresses, then waiting for external-dns to delete the records of: $(tr '\n' ' ' <<<"${hosts}")"
  jq -r '.items[] | select(.metadata.annotations["cloudflare-proxied"] == "enabled") | "\(.metadata.namespace) \(.metadata.name)"' <<<"${ingresses}" \
    | while read -r ns name; do
        kc -n "${ns}" delete ingress "${name}" --ignore-not-found=true --wait=false >/dev/null 2>&1 \
          || warn "could not delete Ingress ${ns}/${name}"
      done
  local deadline=$((SECONDS + DNS_TIMEOUT)) logs
  while (( SECONDS < deadline )); do
    logs="$(kc -n external-dns logs deployment/external-dns --since-time="${start}" 2>/dev/null)" || logs=""
    left=""
    while IFS= read -r host; do
      grep -qF "action=DELETE record=${host} " <<<"${logs}" || left+=" ${host}"
    done <<<"${hosts}"
    # Every DELETE logged, and a later pass found nothing left to change: the deletes went through.
    if [[ -z "${left}" ]] && awk '/action=DELETE/ { d = NR } /All records are already up to date/ { u = NR } END { exit !(u > d) }' <<<"${logs}"; then
      log "external-dns deleted the DNS records"
      return 0
    fi
    sleep 10
  done
  warn "external-dns did not confirm deleting the records of${left:- every host (no clean pass after the deletes)} within ${DNS_TIMEOUT}s - delete them in Cloudflare (A, AAAA and their TXT owner records), or the next cluster skips them"
}

# stop_database_operator - scale every Deployment in cnpg-system (the CloudNativePG operator, the
# barman-cloud plugin) to 0 and wait until their pods are gone, before the app namespaces are deleted.
# Seen on every cloud cycle (2026-10-21/22, Uptrace: "Unable to create the ServiceAccount", "Reconciler
# error" on production/app-postgres) and reproduced on kind: with the operator running, deleting the
# namespace gave dozens of ERRORs in 5 s; deleting the Cluster first still gave one (a status patch racing
# the delete); with the operator stopped, none. CNPG puts no finalizer on a Cluster, its pods or PVCs -
# they go by owner references, so a stopped operator holds nothing up.
stop_database_operator() {
  if ! kc get namespace cnpg-system >/dev/null 2>&1; then
    return 0
  fi
  log "stopping CloudNativePG (operator and plugins), so it does not recreate what the namespaces delete"
  kc -n cnpg-system scale deployment --all --replicas=0 >/dev/null 2>&1 || true
  if ! kc -n cnpg-system wait --for=delete pod --all --timeout=60s >/dev/null 2>&1; then
    warn "CloudNativePG pods still running after 60 s - expect operator errors while the namespaces go"
  fi
}

# stop_pods NS... - delete every pod in these (already terminating) namespaces with grace period 0.
# Their data goes with the cluster; waiting for a graceful stop only keeps disks attached - Postgres
# (CloudNativePG) may take 30 minutes - while the PVs wait and the nodes are billed.
stop_pods() {  # namespace...
  local ns
  for ns in "$@"; do
    log "stopping the pods in ${ns} now (grace period 0)"
    kc -n "${ns}" delete pods --all --grace-period=0 --force --wait=false >/dev/null 2>&1 \
      || warn "could not stop the pods in ${ns} - their disks stay attached until they stop (PVs may outlive the cluster)"
  done
}

# delete_volumes - delete every PVC and wait until the PersistentVolumes are gone; on timeout list
# the ones left (on Hetzner they would outlive the cluster and keep being billed).
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

# delete_namespaces NS... - start deleting each namespace without waiting for it.
delete_namespaces() {  # namespace...
  local ns
  for ns in "$@"; do
    log "deleting namespace ${ns}"
    kc delete namespace "${ns}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  done
}

# wait_for_namespaces NS... - wait up to NS_TIMEOUT for them to disappear; unblock the ones still there.
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
    # Services keep their load-balancer-cleanup finalizer: clearing it would leave the cloud load
    # balancer behind (delete_load_balancers has already waited for them).
    [[ -z "${resource}" || "${resource}" == events* || "${resource}" == services ]] && continue
    kc -n "${ns}" get "${resource}" -o jsonpath='{range .items[?(@.metadata.finalizers)]}{.kind}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | while read -r object; do
          [[ -z "${object}" ]] && continue
          log "  clearing finalizers on ${ns}/${object}"
          kc -n "${ns}" patch "${resource}" "${object#*/}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        done
  done < <(kc api-resources --verbs=list --namespaced -o name 2>/dev/null || true)
  # Clearing the object finalizers often lets the namespace finish on its own.
  sleep 5
  # Gone only when the API says so; if it cannot be checked, still try the finalize below.
  case "$(namespace_state "${ns}")" in
    absent) log "namespace ${ns} deleted"; return 0 ;;
    unknown) warn "could not check namespace ${ns} - trying to finalize it anyway" ;;
  esac
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

# --- main ---
# Without kubectl, a kubeconfig or a reachable API there is nothing this script can clean: warn and
# let Terraform go on (exit 0), as the provisioner continues on failure anyway.
SKIPPED="skipped: suspend Flux, stop Kyverno, remove admission webhooks and PodDisruptionBudgets, delete the namespaces, their pods and PVCs, wait for the PersistentVolumes, clear stuck finalizers, remove Flux"
if ! command -v kubectl >/dev/null 2>&1; then
  warn "kubectl not found - no cluster-side cleanup (${SKIPPED}); volumes created by the cluster may be left behind"
  exit 0
fi
if [[ -z "${KUBECONFIG_PATH}" || ! -f "${KUBECONFIG_PATH}" ]]; then
  warn "kubeconfig '${KUBECONFIG_PATH}' not found - no cluster-side cleanup (${SKIPPED}); volumes created by the cluster may be left behind"
  exit 0
fi
if ! kc version >/dev/null 2>&1; then
  warn "cluster not reachable - no cluster-side cleanup (${SKIPPED}); volumes created by the cluster may be left behind"
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

# The order is the point (see the header): stop Flux and the webhooks, stop CloudNativePG, delete the app namespaces and
# volumes while the cluster can still clean up, and remove Flux last.
suspend_flux
remove_admission_webhooks
remove_disruption_budgets
delete_dns_records
delete_load_balancers
if (( ${#app_namespaces[@]} > 0 )); then
  stop_database_operator
  delete_namespaces "${app_namespaces[@]}"
  stop_pods "${app_namespaces[@]}"
fi
delete_volumes
if (( ${#app_namespaces[@]} > 0 )); then
  wait_for_namespaces "${app_namespaces[@]}"
fi
if [[ "${flux_namespace}" == true ]]; then
  remove_flux
fi

log "pre-destroy cleanup finished"
