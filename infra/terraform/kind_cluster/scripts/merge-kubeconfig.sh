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

export KUBECONFIG="$DEFAULT_KCFG"
DEFAULT_CTX="kind-sre-control-plane"
TARGET_CTX="sre-control-plane"
if kubectl config get-contexts "$TARGET_CTX" >/dev/null 2>&1; then
  exit 0
fi
if kubectl config get-contexts "$DEFAULT_CTX" >/dev/null 2>&1; then
  kubectl config rename-context "$DEFAULT_CTX" "$TARGET_CTX"
fi
