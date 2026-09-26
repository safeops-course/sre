#!/usr/bin/env bash
# After a destroy: fail loudly if anything billable is left in the Hetzner project.
# Terraform only knows what is in its state; the cluster itself creates volumes (CSI) and load
# balancers (CCM) that outlive the nodes if the pre-destroy cleanup could not remove them.
# The project holds only this platform, so anything listed here is a leftover.
#
# Token: HCLOUD_TOKEN, or TF_VAR_hcloud_token (set by the local env file / the workflows).
# Usage: scripts/hcloud-leftovers.sh

set -Eeuo pipefail

token="${HCLOUD_TOKEN:-${TF_VAR_hcloud_token:-}}"
if [[ -z "${token}" ]]; then
  echo "hcloud-leftovers: no Hetzner token (HCLOUD_TOKEN or TF_VAR_hcloud_token)" >&2
  exit 2
fi

left=0
for kind in servers volumes load_balancers primary_ips floating_ips networks firewalls placement_groups; do
  names=$(curl -fsS -H "Authorization: Bearer ${token}" "https://api.hetzner.cloud/v1/${kind}?per_page=50" \
    | jq -r --arg k "${kind}" '.[$k][] | .name')
  if [[ -n "${names}" ]]; then
    echo "LEFT: ${kind}: $(echo "${names}" | tr '\n' ' ')"
    left=1
  fi
done

if (( left )); then
  echo "::error::Hetzner resources left after destroy - they are billed. Delete them in the Hetzner console (project SafeOps) or with the hcloud CLI." >&2
  exit 1
fi
echo "Hetzner project is empty."
