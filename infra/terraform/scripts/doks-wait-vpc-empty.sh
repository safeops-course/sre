#!/usr/bin/env bash
# On destroy, between the DOKS cluster and its VPC (doks_cluster/main.tf terraform_data.vpc_empty): wait
# until no droplet and no load balancer is left in the VPC. DigitalOcean deletes a cluster's nodes in the
# background - the cluster's delete returns at once - and a VPC with members cannot be deleted: the provider
# retries for about 2 minutes, then gives up (2026-10-23: "Can not delete VPC with members", the VPC left).
#
# Usage: doks-wait-vpc-empty.sh <vpc_id>
# Needs: doctl (DOCTL, or doctl on PATH) and jq; DIGITALOCEAN_CONFIG, doctl's config file ("default"
# context). VPC_WAIT_TIMEOUT seconds (default 600). Exit 0 = empty, 1 = still members at the timeout (named),
# 2 = bad usage or a listing failed - the destroy stops there, loudly, rather than leave the VPC quietly.

set -Eeuo pipefail
unset DIGITALOCEAN_ACCESS_TOKEN DIGITALOCEAN_CONTEXT

[[ $# -eq 1 && -n "$1" ]] || { echo "usage: $0 <vpc_id>" >&2; exit 2; }
vpc="$1"
doctl="${DOCTL:-doctl}"
timeout="${VPC_WAIT_TIMEOUT:-600}"
[[ "${timeout}" =~ ^[0-9]+$ ]] || { echo "doks-wait-vpc-empty: VPC_WAIT_TIMEOUT must be whole seconds, got '${timeout}'" >&2; exit 2; }

# members - the names of the droplets and load balancers in the VPC, one per line (empty when none).
members() {
  local droplets lbs
  droplets="$("${doctl}" --context default compute droplet list --output json)" || return 2
  lbs="$("${doctl}" --context default compute load-balancer list --output json)" || return 2
  jq -r --arg vpc "${vpc}" '.[]? | select(.vpc_uuid == $vpc) | "droplet " + .name' <<<"${droplets}"
  jq -r --arg vpc "${vpc}" '.[]? | select(.vpc_uuid == $vpc) | "load balancer " + .name' <<<"${lbs}"
}

waited=0
while :; do
  if ! left="$(members)"; then
    echo "doks-wait-vpc-empty: could not list the VPC's members (doctl error above)" >&2
    exit 2
  fi
  if [[ -z "${left}" ]]; then
    echo "[doks-wait-vpc-empty] VPC ${vpc} has no members after ${waited} s"
    exit 0
  fi
  if (( waited >= timeout )); then
    echo "doks-wait-vpc-empty: still in VPC ${vpc} after ${timeout} s: $(tr '\n' ',' <<<"${left}")" >&2
    exit 1
  fi
  echo "[doks-wait-vpc-empty] waiting for: $(tr '\n' ',' <<<"${left}")"
  sleep 15
  waited=$(( waited + 15 ))
done
