#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/guard-kube-context.sh --context <name> --namespace <name> [--kubeconfig <path>]

Verifies kubectl is pointing to the expected cluster context and namespace.
Fails fast with actionable output if context/namespace checks do not pass.

Examples:
  scripts/guard-kube-context.sh --context sre-control-plane --namespace develop
  scripts/guard-kube-context.sh --context sre-control-plane --namespace production --kubeconfig ./kubeconfig.yaml
EOF
}

EXPECTED_CONTEXT=""
EXPECTED_NAMESPACE=""
KUBECONFIG_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      EXPECTED_CONTEXT="${2:-}"
      shift 2
      ;;
    --namespace)
      EXPECTED_NAMESPACE="${2:-}"
      shift 2
      ;;
    --kubeconfig)
      KUBECONFIG_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[guard-kube] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${EXPECTED_CONTEXT}" || -z "${EXPECTED_NAMESPACE}" ]]; then
  echo "[guard-kube] --context and --namespace are required" >&2
  usage >&2
  exit 2
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[guard-kube] kubectl not found in PATH" >&2
  exit 1
fi

if [[ -n "${KUBECONFIG_PATH}" ]]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [[ -z "${CURRENT_CONTEXT}" ]]; then
  echo "[guard-kube] no current kubectl context is set" >&2
  exit 1
fi

if [[ "${CURRENT_CONTEXT}" != "${EXPECTED_CONTEXT}" ]]; then
  echo "[guard-kube] context mismatch" >&2
  echo "  expected: ${EXPECTED_CONTEXT}" >&2
  echo "  actual:   ${CURRENT_CONTEXT}" >&2
  exit 1
fi

if ! kubectl get namespace "${EXPECTED_NAMESPACE}" >/dev/null 2>&1; then
  echo "[guard-kube] namespace '${EXPECTED_NAMESPACE}' not found in context '${CURRENT_CONTEXT}'" >&2
  exit 1
fi

echo "[guard-kube] OK context=${CURRENT_CONTEXT} namespace=${EXPECTED_NAMESPACE}"
