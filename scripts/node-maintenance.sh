#!/usr/bin/env bash
# OS updates for one node of the Hetzner cluster, at a time we choose: cordon, drain, install the
# updates (transactional-update), reboot, wait for the new boot, uncordon.
#
# Why by hand: the platform turns off the nodes' automatic updates and kured (auto_upgrade_os,
# kured_enabled in infra/terraform/hcloud_cluster). With one worker, every reboot is an outage; one
# kured picks on a Saturday night is an outage nobody planned. The intended cadence is monthly - the
# Renovate dependency dashboard issue (refreshed on the 1st) is the reminder - one node at a time,
# and check the platform between nodes.
#
#   scripts/node-maintenance.sh hetzner-sre-control-plane NODE                    # dry run
#   scripts/node-maintenance.sh hetzner-sre-control-plane NODE --apply            # do it
#   scripts/node-maintenance.sh hetzner-sre-control-plane NODE --apply --accept-outage
#
# The dry run changes nothing: it shows the node and asks the API server what a drain would evict
# (a server-side dry run - PodDisruptionBudgets are checked). With one worker the pods have nowhere
# to go, and a budget like minAvailable: 1 blocks the drain: --apply then stops at the drain, loudly.
# --accept-outage is the decision to take that outage: the drain deletes the pods past their
# budgets instead of waiting for them. Planned, announced, inside a window - not a default.
#
# Needs: kubectl; ssh to the node as root through ssh-agent (the key the cluster was created with).
# Every kubectl call names the given context. Node OS: openSUSE MicroOS / Leap Micro
# (transactional-update installs into a new snapshot, active after the reboot).
set -Eeuo pipefail

context="${1:?usage: $0 KUBE_CONTEXT NODE [--apply [--accept-outage]]}"
node="${2:?usage: $0 KUBE_CONTEXT NODE [--apply [--accept-outage]]}"
shift 2
apply=false
accept_outage=false
for arg in "$@"; do
  case "${arg}" in
    --apply) apply=true ;;
    --accept-outage) accept_outage=true ;;
    *) echo "error: unknown argument '${arg}' - use --apply and optionally --accept-outage" >&2; exit 2 ;;
  esac
done
if [[ "${accept_outage}" == true && "${apply}" != true ]]; then
  echo "error: --accept-outage only makes sense with --apply" >&2
  exit 2
fi
ssh_user="${SSH_USER:-root}"
ssh_port="${SSH_PORT:-22}"
drain_timeout="${DRAIN_TIMEOUT:-10m}"
reboot_timeout_s="${REBOOT_TIMEOUT_S:-900}"

# kube <args> - kubectl against the given context; the only way this script talks to a cluster.
kube() { kubectl --context "${context}" "$@"; }

# on_node <command> - run a command on the node over ssh (no host key prompt for a fresh node).
on_node() {
  ssh -p "${ssh_port}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "${ssh_user}@${address}" "$@"
}

# Fail loudly with the step that failed - the node may be left cordoned; the message says so.
trap 'echo "error: stopped at line ${LINENO} - ${node} may still be cordoned: kubectl --context ${context} uncordon ${node} once it is healthy" >&2' ERR

boot_id="$(kube get node "${node}" -o jsonpath='{.status.nodeInfo.bootID}')"
address="$(kube get node "${node}" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')"
roles="$(kube get node "${node}" -o jsonpath='{.metadata.labels}' | grep -o 'node-role.kubernetes.io/[a-z-]*' | sed 's|.*/||' | sort -u | tr '\n' ' ' || true)"
echo "node ${node} (${address:-no ExternalIP}) roles: ${roles:-worker}; boot ${boot_id}"
if [[ "${roles}" == *control-plane* ]]; then
  echo "note: a control-plane node - with one control plane the API is down while it reboots"
fi

echo "== what a drain would evict (server-side dry run; PodDisruptionBudgets are checked)"
# A blocked eviction is retried until --timeout - without one the dry run would wait forever.
if dry="$(kube drain "${node}" --ignore-daemonsets --delete-emptydir-data --dry-run=server --timeout=60s 2>&1)"; then
  echo "${dry}" | { grep '^evicting pod' || true; } | sort -u   # nothing to evict is not an error
  echo "a drain would complete"
else
  echo "${dry}" | { grep '^evicting pod' || true; } | sort -u   # nothing to evict is not an error
  blocked="$(echo "${dry}" | sed -n 's/.*evicting pods\/"\([^"]*\)" -n "\([^"]*\)".*disruption budget.*/\2\/\1/p' | sort -u)"
  if [[ -n "${blocked}" ]]; then
    echo "a drain would be BLOCKED by these pods' PodDisruptionBudgets (nowhere else to run them):"
    while IFS= read -r pod; do echo "  ${pod}"; done <<<"${blocked}"
    echo "--apply would stop at the drain; --apply --accept-outage deletes them and takes the outage."
  else
    echo "${dry}" | tail -3 >&2
    echo "error: the dry run failed for another reason - see above" >&2
    exit 1
  fi
fi

if [[ "${apply}" != true ]]; then
  echo "dry run only - nothing changed. Run again with --apply to cordon, drain, update and reboot ${node}."
  exit 0
fi

# A kind node is a container: no ExternalIP and no OS of its own - the dry run works there, --apply not.
[[ -n "${address}" ]] || { echo "error: ${node} has no ExternalIP to ssh to - --apply needs a real node" >&2; exit 1; }

echo "== cordon and drain"
kube cordon "${node}"
if [[ "${accept_outage}" == true ]]; then
  # --disable-eviction deletes pods instead of evicting them: budgets do not hold it back. The
  # outage was chosen; the pods come back when the node does.
  kube drain "${node}" --ignore-daemonsets --delete-emptydir-data --disable-eviction --timeout="${drain_timeout}"
else
  kube drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout="${drain_timeout}"
fi

echo "== install updates (transactional-update: a new snapshot, active after the reboot)"
on_node transactional-update --non-interactive up

echo "== reboot"
# The connection drops when the node goes down - ssh's exit code says nothing about the reboot.
on_node systemctl reboot || true

echo "== wait for a new boot (up to ${reboot_timeout_s}s)"
deadline=$(( $(date +%s) + reboot_timeout_s ))
while :; do
  # The API itself may be gone while a control plane reboots: a failed read is retried, not fatal.
  now_boot="$(kube get node "${node}" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null || true)"
  ready="$(kube get node "${node}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ -n "${now_boot}" && "${now_boot}" != "${boot_id}" && "${ready}" == "True" ]]; then
    echo "booted: ${now_boot}, Ready"
    break
  fi
  if (( $(date +%s) > deadline )); then
    echo "error: ${node} did not come back with a new boot within ${reboot_timeout_s}s - it stays cordoned" >&2
    exit 1
  fi
  sleep 10
done

echo "== uncordon"
kube uncordon "${node}"
trap - ERR
echo "done: ${node} updated and back. Check the platform before the next node (Flux Ready, smoke test)."
