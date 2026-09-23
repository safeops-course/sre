#!/usr/bin/env bash
set -euo pipefail
NEW_KCFG=${1:-}
if [[ -z "$NEW_KCFG" || ! -f "$NEW_KCFG" ]]; then
  echo "usage: merge-kubeconfig.sh <kubeconfig_path>" >&2
  exit 1
fi
DEFAULT_KCFG="$HOME/.kube/config"
mkdir -p "$HOME/.kube"
TMP_MERGE="$(mktemp)"
if [[ -f "$DEFAULT_KCFG" ]]; then
  KUBECONFIG="$DEFAULT_KCFG:$NEW_KCFG" kubectl config view --flatten > "$TMP_MERGE"
else
  cp "$NEW_KCFG" "$TMP_MERGE"
fi
mv "$TMP_MERGE" "$DEFAULT_KCFG"
chmod 600 "$DEFAULT_KCFG"

# The context keeps kind's own name, kind-<cluster>, e.g. kind-sre-control-plane.
# It is not renamed: a bare name is left for the Hetzner cluster.
