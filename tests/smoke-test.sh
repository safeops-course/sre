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
# The backend Service listens on port 80 (targetPort http=8080).
# The probe pod carries app=frontend (develop is default-deny; only frontend
# and Traefik may reach the backend) and a restricted-PSS-compliant spec.
# No `--rm -i`: attaching to a pod that exits in <1s races and reports a
# timeout; create it, wait for completion, read the exit status, delete it.
smoke_curl() {
  local ns="develop" pod="smoke-curl"
  kubectl -n "$ns" delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl run "$pod" --image=curlimages/curl --labels=app=frontend --restart=Never -n "$ns" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"smoke-curl","image":"curlimages/curl","command":["curl","-sf","-m","10","http://backend.develop.svc.cluster.local/healthz"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
  local phase="" i
  for i in $(seq 1 30); do
    phase="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)"
    [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
    sleep 2
  done
  kubectl -n "$ns" delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1
  [ "$phase" = "Succeeded" ]
}
run_test "Backend /healthz responds in develop" smoke_curl

# --- 4. Critical secrets present ---
# (uptrace-secrets is not part of flux/secrets/develop; the DSN lives in backend-secrets)
for secret in backend-secrets app-postgres-app; do
  run_test "Secret $secret exists in develop" \
    kubectl get secret "$secret" -n develop
done

# --- 5. Certificates valid ---
run_test "cert-manager Certificate resources are Ready" \
  bash -c 'kubectl get certificates -A -o jsonpath="{.items[*].status.conditions[?(@.type==\"Ready\")].status}" | tr " " "\n" | grep -v True | wc -l | grep -q "^0$"'

# --- 6. CNPG clusters healthy ---
run_test "CNPG clusters are Running" \
  bash -c 'kubectl get clusters.postgresql.cnpg.io -A -o jsonpath="{range .items[*]}{.status.phase}{\"\\n\"}{end}" | grep -v "^Cluster in healthy state$" | grep -v "^$" | wc -l | grep -q "^0$"'

# --- Summary ---
echo ""
echo "# Tests: $TOTAL, Pass: $PASS, Fail: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
