#!/usr/bin/env bash
# After an AKS destroy: fail loudly if anything billable is left in the Azure subscription.
# Terraform only knows what is in its state; the cluster itself creates disks (CSI), a load balancer and
# public addresses (cloud controller) that outlive it if the pre-destroy cleanup could not remove them.
# The subscription holds only this platform, so anything listed here is a leftover: the cluster, anything
# in its group <cluster_name>-aks (empty between cycles), the node group <cluster_name>-aks-nodes, and -
# wherever they are - disks, snapshots, public IPs, load balancers, virtual networks and Log Analytics
# workspaces.
#
# Usage: scripts/aks-leftovers.sh [--settle] <cluster_name>
#   --settle  after a successful destroy: Azure lists a deleted resource for a while after its delete
#             returned (2026-10-22: `az resource list` still named the cluster right after the destroy,
#             a minute later it did not), so everything is checked up to LEFTOVERS_ATTEMPTS times in all
#             (default 5: the first check and 4 more), LEFTOVERS_WAIT seconds apart (default 30, so up to
#             2 minutes of waiting); the last answer counts. Until then a listed resource is printed as
#             "still listed", not LEFT. A failed query is not retried - it is no lag.
#
# Runs at the end of the aks_cluster Makefile's destroy (with --settle when the destroy succeeded) and as
# its `make leftovers`. Needs: az, signed in from AZURE_CONFIG_DIR; TF_VAR_subscription_id. Changes
# nothing - it only lists. Exit 0 = empty, 1 = something left, 2 = bad usage or a query failed: an error
# never reads as "nothing left". Called through make, both 1 and 2 surface as make's own exit 2.

set -Eeuo pipefail

usage() {
  echo "usage: TF_VAR_subscription_id=... $0 [--settle] <cluster_name>" >&2
  exit 2
}

# Arguments: --settle and one cluster name, in any order; anything else is refused - a flag that is
# silently dropped would turn the settled check into a single one.
settle=0
cluster=""
for arg in "$@"; do
  case "${arg}" in
    --settle) settle=1 ;;
    -*) usage ;;
    *) [[ -z "${cluster}" ]] || usage; cluster="${arg}" ;;
  esac
done
sub="${TF_VAR_subscription_id:-}"
if [[ -z "${cluster}" || -z "${sub}" ]]; then usage; fi

attempts=1
wait_s=0
if (( settle )); then
  attempts="${LEFTOVERS_ATTEMPTS:-5}"
  wait_s="${LEFTOVERS_WAIT:-30}"
  # 0 attempts would check nothing and read as "nothing left".
  if [[ ! "${attempts}" =~ ^[1-9][0-9]*$ ]]; then
    echo "aks-leftovers: LEFTOVERS_ATTEMPTS must be a positive integer, got '${attempts}'" >&2
    exit 2
  fi
  if [[ ! "${wait_s}" =~ ^[0-9]+$ ]]; then
    echo "aks-leftovers: LEFTOVERS_WAIT must be a whole number of seconds, got '${wait_s}'" >&2
    exit 2
  fi
fi

rg="${cluster}-aks"
nodes_rg="${cluster}-aks-nodes" # aks_cluster/main.tf local.node_resource_group

# check_once LABEL - list every kind once; prints a line per kind that lists something, starting with LABEL
# (LEFT, or "still listed" before the last settle attempt), and FAIL lines. Returns 0 empty, 1 left,
# 2 a query failed.
# The subscription goes after the command: `az --subscription X aks list` is refused (seen 2026-10-21).
# Disks and snapshots through `az resource list`: `az disk list` without a resource group is refused (az 2.91).
check_once() {
  local label="$1" left=0 failed=0
  # check <what> <az args...> - one listing; names found make it "left", an az error makes it "failed".
  check() {
    local what="$1" out
    shift
    if ! out="$(az "$@" --subscription "${sub}" --output tsv)"; then
      failed=1
      echo "FAIL could not list ${what} (az error above)" >&2
      return 0
    fi
    if [[ -n "${out}" ]]; then
      left=1
      echo "${label} ${what}: $(tr '\t\n' '  ' <<<"${out}")"
    fi
  }
  check "AKS clusters"             aks list --query '[].name'
  check "resources in ${rg}"       resource list --resource-group "${rg}" --query '[].name'
  check "node resource group"      group list --query "[?name=='${nodes_rg}'].name"
  check "disks"                    resource list --resource-type Microsoft.Compute/disks --query '[].name'
  check "snapshots"                resource list --resource-type Microsoft.Compute/snapshots --query '[].name'
  check "public IPs"               network public-ip list --query '[].name'
  check "load balancers"           network lb list --query '[].name'
  check "virtual networks"         network vnet list --query '[].name'
  check "Log Analytics workspaces" monitor log-analytics workspace list --query '[].name'
  if (( failed )); then return 2; fi
  if (( left )); then return 1; fi
  echo "OK   nothing left in subscription ${sub}"
  return 0
}

for (( attempt = 1; ; attempt++ )); do
  label="LEFT"
  if (( attempt < attempts )); then label="     still listed"; fi
  rc=0
  check_once "${label}" || rc=$?
  if (( rc != 1 || attempt >= attempts )); then exit "${rc}"; fi
  echo "     Azure may still list what was just deleted - checking again in ${wait_s} s (${attempt}/${attempts})"
  sleep "${wait_s}"
done
