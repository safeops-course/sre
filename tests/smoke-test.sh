#!/usr/bin/env bash
# Infrastructure smoke tests for the SRE platform.
# Validates a running cluster by checking core components.
#
# Requirements: kubectl (configured with cluster access), flux CLI
# Exit codes: 0 = all pass, 1 = one or more failures
# Output: TAP-like format (test name + pass/fail)
set -Eeuo pipefail

PASS=0
FAIL=0
TOTAL=0

pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "ok $TOTAL - $1"
}

fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "not ok $TOTAL - $1"
}

run_test() {
  local name="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    pass "$name"
  else
    fail "$name"
  fi
}

# --- 1. Flux health ---
run_test "Flux check passes" flux check

run_test "All Kustomizations are ready" \
  bash -c 'kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system -o jsonpath="{.items[*].status.conditions[?(@.type==\"Ready\")].status}" | tr " " "\n" | grep -v True | wc -l | grep -q "^0$"'

# --- 2. Core deployments available ---
for deploy in frontend backend; do
  run_test "Deployment $deploy in develop is Available" \
    kubectl rollout status deployment/"$deploy" -n develop --timeout=10s
done

# --- 3. Services reachable ---
run_test "Backend /healthz responds in develop" \
  bash -c 'kubectl run smoke-curl --image=curlimages/curl --rm -i --restart=Never -n develop --timeout=30s -- curl -sf http://backend.develop.svc.cluster.local:8080/healthz'

# --- 4. Critical secrets present ---
for secret in backend-secrets uptrace-secrets; do
  run_test "Secret $secret exists in develop" \
    kubectl get secret "$secret" -n develop
done

# --- 5. Certificates valid ---
run_test "cert-manager Certificate resources are Ready" \
  bash -c 'kubectl get certificates -A -o jsonpath="{.items[*].status.conditions[?(@.type==\"Ready\")].status}" | tr " " "\n" | grep -v True | wc -l | grep -q "^0$"'

# --- 6. CNPG clusters healthy ---
run_test "CNPG clusters are Running" \
  bash -c 'kubectl get clusters.postgresql.cnpg.io -A -o jsonpath="{.items[*].status.phase}" | tr " " "\n" | grep -v "Cluster in healthy state" | grep -v "^$" | wc -l | grep -q "^0$"'

# --- Summary ---
echo ""
echo "# Tests: $TOTAL, Pass: $PASS, Fail: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
