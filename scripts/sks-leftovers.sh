#!/usr/bin/env bash
# After an SKS destroy: fail loudly if anything billable is left in the Exoscale organization.
# Terraform only knows what is in its state; the cluster itself creates network load balancers (cloud
# controller) and block storage volumes (CSI) that outlive it - on Exoscale a deleted cluster leaves them,
# billed, unless the pre-destroy cleanup deleted them. The organization holds only this platform, so anything
# listed in the cycle's zone is a leftover: SKS clusters, instance pools and instances (the nodes), network
# load balancers, block storage volumes and their snapshots; and, in the whole organization, the cycle's
# security group <cluster_name>-sks-nodes (free, but the next cycle could not create it).
# Only the cycle's zone: everything the cycle creates is there, and a listing of every zone fails whenever
# one zone does not answer (2026-10-23: at-vie-1 timed out) - an error that is no leftover.
#
# Usage: scripts/sks-leftovers.sh [--settle] <cluster_name> <zone>
#   --settle  after a successful destroy: Exoscale may still be deleting the load balancer and the volumes
#             the pre-destroy hook asked for, so everything is checked up to LEFTOVERS_ATTEMPTS times in all
#             (default 5: the first check and 4 more), LEFTOVERS_WAIT seconds apart (default 30, so up to 2
#             minutes of waiting); the last answer counts. Until then a listed resource is printed as "still
#             listed", not LEFT. A failed query is not retried - it is no lag. The same as
#             scripts/doks-leftovers.sh.
#
# Runs at the end of the sks_cluster Makefile's destroy (with --settle when the destroy succeeded) and as
# its `make leftovers`. Needs: exo (EXO, as the Makefile exports it, or exo on PATH) and jq;
# EXOSCALE_CONFIG, exo's config file with the API key (exo reads the variable itself). A key or an account
# in the environment would win over that file, so EXOSCALE_API_KEY, EXOSCALE_API_SECRET and EXOSCALE_ACCOUNT
# are cleared - a direct run lists the same organization as make does. Changes nothing - it only lists.
# Exit 0 = empty, 1 = something left, 2 = bad usage or a query failed: an error never reads as "nothing
# left". Called through make, both 1 and 2 surface as make's own exit 2.

set -Eeuo pipefail
unset EXOSCALE_API_KEY EXOSCALE_API_SECRET EXOSCALE_ACCOUNT

usage() {
  echo "usage: EXOSCALE_CONFIG=... $0 [--settle] <cluster_name> <zone>" >&2
  exit 2
}

# Arguments: --settle, the cluster name and the zone, in this order but for --settle; anything else is
# refused - a flag that is silently dropped would turn the settled check into a single one.
settle=0
names=()
for arg in "$@"; do
  case "${arg}" in
    --settle) settle=1 ;;
    -*) usage ;;
    *) names+=("${arg}") ;;
  esac
done
(( ${#names[@]} == 2 )) || usage
cluster="${names[0]}"
zone="${names[1]}"
if [[ -z "${EXOSCALE_CONFIG:-}" || ! -f "${EXOSCALE_CONFIG}" ]]; then
  echo "sks-leftovers: EXOSCALE_CONFIG ('${EXOSCALE_CONFIG:-}') is not exo's config file - set it (.env.sks)" >&2
  exit 2
fi

attempts=1
wait_s=0
if (( settle )); then
  attempts="${LEFTOVERS_ATTEMPTS:-5}"
  wait_s="${LEFTOVERS_WAIT:-30}"
  # 0 attempts would check nothing and read as "nothing left".
  if [[ ! "${attempts}" =~ ^[1-9][0-9]*$ ]]; then
    echo "sks-leftovers: LEFTOVERS_ATTEMPTS must be a positive integer, got '${attempts}'" >&2
    exit 2
  fi
  if [[ ! "${wait_s}" =~ ^[0-9]+$ ]]; then
    echo "sks-leftovers: LEFTOVERS_WAIT must be a whole number of seconds, got '${wait_s}'" >&2
    exit 2
  fi
fi

security_group="${cluster}-sks-nodes" # sks_cluster/main.tf exoscale_security_group.nodes
exo="${EXO:-exo}"

# check_once LABEL - list every kind once; prints a line per kind that lists something, starting with LABEL
# (LEFT, or "still listed" before the last settle attempt), and FAIL lines. Returns 0 empty, 1 left,
# 2 a query failed.
check_once() {
  local label="$1" left=0 failed=0
  # check WHAT JQ EXO_ARGS... - one listing as JSON (-O json); JQ turns it into names, one per line. Names
  # make it "left", an error "failed".
  check() {
    local what="$1" filter="$2" json names
    shift 2
    if ! json="$("${exo}" "$@" -O json)"; then
      failed=1
      echo "FAIL could not list ${what} (exo error above)" >&2
      return 0
    fi
    if ! names="$(jq -r "${filter}" <<<"${json}")"; then
      failed=1
      echo "FAIL could not read the list of ${what}" >&2
      return 0
    fi
    if [[ -n "${names}" ]]; then
      left=1
      echo "${label} ${what}: $(tr '\n' ' ' <<<"${names}")"
    fi
  }
  check "SKS clusters in ${zone}"           '.[]? | .name' compute sks list --zone "${zone}"
  check "instance pools in ${zone}"         '.[]? | .name' compute instance-pool list --zone "${zone}"
  check "instances in ${zone}"              '.[]? | .name' compute instance list --zone "${zone}"
  check "load balancers in ${zone}"         '.[]? | .name' compute load-balancer list --zone "${zone}"
  check "block storage volumes in ${zone}"  '.[]? | .name' compute block-storage list --zone "${zone}"
  check "volume snapshots in ${zone}"       '.[]? | .name' compute block-storage snapshot list --zone "${zone}"
  check "security group ${security_group}"  ".[]? | select(.name == \"${security_group}\") | .name" compute security-group list
  if (( failed )); then return 2; fi
  if (( left )); then return 1; fi
  echo "OK   nothing left in the Exoscale organization (zone ${zone})"
  return 0
}

for (( attempt = 1; ; attempt++ )); do
  label="LEFT"
  if (( attempt < attempts )); then label="     still listed"; fi
  rc=0
  check_once "${label}" || rc=$?
  if (( rc != 1 || attempt >= attempts )); then exit "${rc}"; fi
  echo "     Exoscale may still be deleting it - checking again in ${wait_s} s (${attempt}/${attempts})"
  sleep "${wait_s}"
done
