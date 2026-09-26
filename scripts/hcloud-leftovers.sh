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

# The header comes from a process substitution (printf is a shell builtin), so the token never
# appears in curl's arguments - other accounts on the machine could read those with ps.
list_names() {
  local kind="$1"
  curl -fsS --connect-timeout 10 --max-time 30 \
    -H @<(printf 'Authorization: Bearer %s\n' "${token}") \
    "https://api.hetzner.cloud/v1/${kind}?per_page=50" \
    | jq -r --arg k "${kind}" \
      'if (.[$k] | type) == "array" then .[$k][].name else error("no \($k) array in the API response") end'
}

left=0
for kind in servers volumes load_balancers primary_ips floating_ips networks firewalls placement_groups; do
  # An API error or an unexpected response is not "nothing left" - stop.
  if ! names=$(list_names "${kind}"); then
    echo "::error::hcloud-leftovers: could not list ${kind} - the project is NOT verified empty" >&2
    exit 2
  fi
  if [[ -n "${names}" ]]; then
    echo "LEFT: ${kind}: $(echo "${names}" | tr '\n' ' ')"
    left=1
  fi
done

if (( left )); then
  echo "::error::Hetzner resources left after destroy (servers, volumes, load balancers and IPs are billed; networks, firewalls and placement groups are not, but block a clean state). Re-run the destroy - a transient Hetzner API error is the usual cause - or delete them in the Hetzner console / with the hcloud CLI." >&2
  exit 1
fi
echo "Hetzner project is empty."
