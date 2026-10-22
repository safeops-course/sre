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
#             a minute later it did not), so "left" is checked again, LEFTOVERS_ATTEMPTS times (default 4)
#             LEFTOVERS_WAIT seconds apart (default 30); the last answer counts. A failed query is not
#             retried - it is no lag.
#
# Runs at the end of the aks_cluster Makefile's destroy (with --settle when the destroy succeeded) and as
# its `make leftovers`. Needs: az, signed in from AZURE_CONFIG_DIR; TF_VAR_subscription_id. Changes
# nothing - it only lists. Exit 0 = empty, 1 = something left, 2 = bad usage or a query failed: an error
# never reads as "nothing left". Called through make, both 1 and 2 surface as make's own exit 2.

set -Eeuo pipefail

settle=0
if [[ "${1:-}" == "--settle" ]]; then settle=1; shift; fi
cluster="${1:-}"
sub="${TF_VAR_subscription_id:-}"
attempts="${LEFTOVERS_ATTEMPTS:-4}"
wait_s="${LEFTOVERS_WAIT:-30}"

if [[ -z "${cluster}" || -z "${sub}" ]]; then
  echo "usage: TF_VAR_subscription_id=... $0 [--settle] <cluster_name>" >&2
  exit 2
fi
# 0 attempts would check nothing and read as "nothing left".
if [[ ! "${attempts}" =~ ^[1-9][0-9]*$ ]]; then
  echo "aks-leftovers: LEFTOVERS_ATTEMPTS must be a positive integer, got '${attempts}'" >&2
  exit 2
fi
if [[ ! "${wait_s}" =~ ^[0-9]+$ ]]; then
  echo "aks-leftovers: LEFTOVERS_WAIT must be a whole number of seconds, got '${wait_s}'" >&2
  exit 2
fi

rg="${cluster}-aks"
nodes_rg="${cluster}-aks-nodes"

# check_once - list every kind once; prints LEFT/FAIL lines. Returns 0 empty, 1 left, 2 a query failed.
# The subscription goes after the command: `az --subscription X aks list` is refused (seen 2026-10-21).
# Disks and snapshots through `az resource list`: `az disk list` without a resource group is refused (az 2.91).
check_once() {
  local left=0 failed=0
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
      echo "LEFT ${what}: $(tr '\t\n' '  ' <<<"${out}")"
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

(( settle )) || attempts=1
for (( attempt = 1; ; attempt++ )); do
  rc=0
  check_once || rc=$?
  if (( rc != 1 || attempt >= attempts )); then exit "${rc}"; fi
  echo "     Azure may still list what was just deleted - checking again in ${wait_s} s (${attempt}/${attempts})"
  sleep "${wait_s}"
done
