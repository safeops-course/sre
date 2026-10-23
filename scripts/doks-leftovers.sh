#!/usr/bin/env bash
# After a DOKS destroy: fail loudly if anything billable is left in the DigitalOcean team.
# Terraform only knows what is in its state; the cluster itself creates load balancers (cloud controller)
# and volumes (CSI) that outlive it - on DigitalOcean a deleted cluster leaves them, billed, unless the
# destroy deleted them or the pre-destroy cleanup did. The team holds only this platform, so anything listed
# here is a leftover: Kubernetes clusters, droplets (nodes), load balancers, volumes, volume snapshots, and
# the cycle's VPC <cluster_name>-doks (free, but its range would make the next cycle's VPC fail).
#
# Usage: scripts/doks-leftovers.sh [--settle] <cluster_name>
#   --settle  after a successful destroy: DigitalOcean deletes the cluster's load balancers and volumes in
#             the background (destroy_all_associated_resources, and the PVCs the pre-destroy hook deleted
#             without waiting), so everything is checked up to LEFTOVERS_ATTEMPTS times in all (default 5:
#             the first check and 4 more), LEFTOVERS_WAIT seconds apart (default 30, so up to 2 minutes of
#             waiting); the last answer counts. Until then a listed resource is printed as "still listed",
#             not LEFT. A failed query is not retried - it is no lag. The same as scripts/aks-leftovers.sh.
#
# Runs at the end of the doks_cluster Makefile's destroy (with --settle when the destroy succeeded) and as
# its `make leftovers`. Needs: doctl (DOCTL, as the Makefile exports it, or doctl on PATH) and jq;
# DIGITALOCEAN_CONFIG, doctl's config file with the token in its "default" context (doctl reads the
# variable itself). A token in the environment would win over that file,
# so DIGITALOCEAN_ACCESS_TOKEN and DIGITALOCEAN_CONTEXT are cleared - a direct run lists the same team as
# make does. Changes nothing - it only lists. Exit 0 = empty, 1 = something left, 2 = bad usage or a query
# failed: an error never reads as "nothing left". Called through make, both 1 and 2 surface as make's own
# exit 2.

set -Eeuo pipefail
unset DIGITALOCEAN_ACCESS_TOKEN DIGITALOCEAN_CONTEXT

usage() {
  echo "usage: DIGITALOCEAN_CONFIG=... $0 [--settle] <cluster_name>" >&2
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
[[ -n "${cluster}" ]] || usage
if [[ -z "${DIGITALOCEAN_CONFIG:-}" || ! -f "${DIGITALOCEAN_CONFIG}" ]]; then
  echo "doks-leftovers: DIGITALOCEAN_CONFIG ('${DIGITALOCEAN_CONFIG:-}') is not doctl's config file - set it (.env.doks)" >&2
  exit 2
fi

attempts=1
wait_s=0
if (( settle )); then
  attempts="${LEFTOVERS_ATTEMPTS:-5}"
  wait_s="${LEFTOVERS_WAIT:-30}"
  # 0 attempts would check nothing and read as "nothing left".
  if [[ ! "${attempts}" =~ ^[1-9][0-9]*$ ]]; then
    echo "doks-leftovers: LEFTOVERS_ATTEMPTS must be a positive integer, got '${attempts}'" >&2
    exit 2
  fi
  if [[ ! "${wait_s}" =~ ^[0-9]+$ ]]; then
    echo "doks-leftovers: LEFTOVERS_WAIT must be a whole number of seconds, got '${wait_s}'" >&2
    exit 2
  fi
fi

vpc="${cluster}-doks" # doks_cluster/main.tf digitalocean_vpc.this
doctl="${DOCTL:-doctl}"

# check_once LABEL - list every kind once; prints a line per kind that lists something, starting with LABEL
# (LEFT, or "still listed" before the last settle attempt), and FAIL lines. Returns 0 empty, 1 left,
# 2 a query failed.
check_once() {
  local label="$1" left=0 failed=0
  # check WHAT JQ DOCTL_ARGS... - one listing as JSON (`--output json`, context "default" of
  # DIGITALOCEAN_CONFIG); JQ turns it into names, one per line. Names make it "left", an error "failed".
  check() {
    local what="$1" filter="$2" json names
    shift 2
    if ! json="$("${doctl}" --context default "$@" --output json)"; then
      failed=1
      echo "FAIL could not list ${what} (doctl error above)" >&2
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
  # An empty list is `[]` or, for some doctl commands, `null` - `.[]?` takes both.
  check "Kubernetes clusters" '.[]? | .name'                       kubernetes cluster list
  check "droplets"            '.[]? | .name'                       compute droplet list
  check "load balancers"      '.[]? | .name'                       compute load-balancer list
  check "volumes"             '.[]? | .name'                       compute volume list
  check "volume snapshots"    '.[]? | .name'                       compute snapshot list --resource volume
  check "VPC ${vpc}"          ".[]? | select(.name == \"${vpc}\") | .name" vpcs list
  if (( failed )); then return 2; fi
  if (( left )); then return 1; fi
  echo "OK   nothing left in the DigitalOcean team"
  return 0
}

for (( attempt = 1; ; attempt++ )); do
  label="LEFT"
  if (( attempt < attempts )); then label="     still listed"; fi
  rc=0
  check_once "${label}" || rc=$?
  if (( rc != 1 || attempt >= attempts )); then exit "${rc}"; fi
  echo "     DigitalOcean may still be deleting it - checking again in ${wait_s} s (${attempt}/${attempts})"
  sleep "${wait_s}"
done
