#!/usr/bin/env bash
# After a DOKS destroy: fail loudly if anything billable is left in the DigitalOcean team.
# Terraform only knows what is in its state; the cluster itself creates load balancers (cloud controller)
# and volumes (CSI) that outlive it - on DigitalOcean a deleted cluster leaves them, billed, unless the
# destroy deleted them or the pre-destroy cleanup did. The team holds only this platform, so anything listed
# here is a leftover: Kubernetes clusters, droplets (nodes), load balancers, volumes, volume snapshots, and
# the cycle's VPC <cluster_name>-doks (free, but its range would make the next cycle's VPC fail).
#
# Usage: scripts/doks-leftovers.sh <cluster_name>
#
# Runs at the end of the doks_cluster Makefile's destroy and as its `make leftovers`. Needs: doctl and jq;
# DIGITALOCEAN_CONFIG, doctl's config file with the token in its "default" context (doctl reads the
# variable itself). Changes nothing - it only lists. Exit 0 = empty, 1 = something left, 2 = bad usage or
# a query failed: an error never reads as "nothing left". Called through make, both 1 and 2 surface as
# make's own exit 2.

set -Eeuo pipefail

usage() {
  echo "usage: DIGITALOCEAN_CONFIG=... $0 <cluster_name>" >&2
  exit 2
}

[[ $# -eq 1 && -n "$1" && "$1" != -* ]] || usage
cluster="$1"
if [[ -z "${DIGITALOCEAN_CONFIG:-}" || ! -f "${DIGITALOCEAN_CONFIG}" ]]; then
  echo "doks-leftovers: DIGITALOCEAN_CONFIG ('${DIGITALOCEAN_CONFIG:-}') is not doctl's config file - set it (.env.doks)" >&2
  exit 2
fi
vpc="${cluster}-doks" # doks_cluster/main.tf digitalocean_vpc.this

left=0
failed=0

# check WHAT JQ DOCTL_ARGS... - one listing as JSON (`--output json`, context "default" of
# DIGITALOCEAN_CONFIG); JQ turns it into names, one per line. Names make it "left", an error "failed".
check() {
  local what="$1" filter="$2" json names
  shift 2
  if ! json="$(doctl --context default "$@" --output json)"; then
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
    echo "LEFT ${what}: $(tr '\n' ' ' <<<"${names}")"
  fi
}

# An empty list is `[]` or, for some doctl commands, `null` - `.[]?` takes both.
check "Kubernetes clusters" '.[]? | .name'                       kubernetes cluster list
check "droplets"            '.[]? | .name'                       compute droplet list
check "load balancers"      '.[]? | .name'                       compute load-balancer list
check "volumes"             '.[]? | .name'                       compute volume list
check "volume snapshots"    '.[]? | .name'                       compute snapshot list --resource volume
check "VPC ${vpc}"          ".[]? | select(.name == \"${vpc}\") | .name" vpcs list

if (( failed )); then exit 2; fi
if (( left )); then exit 1; fi
echo "OK   nothing left in the DigitalOcean team"
