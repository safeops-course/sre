#!/usr/bin/env bash
# Infrastructure smoke tests for the SRE platform.
# Validates a running cluster by checking core components.
#
# Requirements: kubectl, flux CLI, jq, and KUBE_CONTEXT - the kubeconfig context
# of the cluster to test (`make smoke-test` sets kind-sre-control-plane).
# Every kubectl/flux call names that context: the test also creates and deletes a
# pod, and it must never land on whatever the shared current context is (Chapter 01).
# Exit codes: 0 = all pass, 1 = one or more failures, 2 = no or unknown context
# Output: TAP-like format (test name + pass/fail)
#
# Usage: make smoke-test   (or KUBE_CONTEXT=<context> bash tests/smoke-test.sh)
# Runs by hand as the baseline check of every chapter (Chapter 00), and in the Hetzner e2e workflow
# with KUBE_CONTEXT=hetzner-sre-control-plane.
# What it checks: Flux (every Kustomization Ready and none suspended), the backend and frontend in
# develop, a request to the backend, every app pod answering on each of its addresses (IPv4 and
# IPv6) in every environment, the generated secrets, cert-manager Certificates (skipped where
# cert-manager is not installed) and the CNPG clusters. A check that cannot read its
# objects, or finds none, fails - an empty answer is never "all healthy". It changes nothing in the cluster except
# one short-lived probe pod (smoke-curl-<time>-<random> in develop), which it deletes again.
set -Eeuo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
if [ -z "$KUBE_CONTEXT" ]; then
  echo "smoke-test: set KUBE_CONTEXT (make smoke-test uses kind-sre-control-plane)" >&2
  exit 2
fi
if ! kubectl config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1; then
  echo "smoke-test: context '$KUBE_CONTEXT' not found in the kubeconfig" >&2
  exit 2
fi
export KUBE_CONTEXT
echo "# cluster: $KUBE_CONTEXT"

# The only way this script talks to a cluster.
# k / f ARGS... - kubectl / flux against KUBE_CONTEXT.
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }
f() { flux --context "$KUBE_CONTEXT" "$@"; }

PASS=0
FAIL=0
TOTAL=0

# pass NAME / fail NAME - count the result and print one TAP line.
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

# run_test NAME COMMAND... - run the command quietly; exit 0 is a pass, anything else a fail.
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
run_test "Flux check passes" f check

# kustomizations_ready - true when the Kustomizations can be listed, there is at least one, every
# one is Ready=True and none is suspended. A suspended one keeps showing Ready while it ignores Git
# (Chapter 03), so Ready alone would call a stopped delivery healthy.
kustomizations_ready() {
  local rows
  rows="$(k get kustomizations.kustomize.toolkit.fluxcd.io -A \
    -o jsonpath='{range .items[*]}{.metadata.name} {.spec.suspend} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')" || return 1
  [ -n "$rows" ] || return 1
  # Every row must read "<name> <false or empty> True".
  ! printf '%s\n' "$rows" | awk '$2 == "true" || $NF != "True" { bad = 1 } END { exit !bad }'
}
run_test "All Kustomizations are Ready and none is suspended" kustomizations_ready

# --- 2. Core deployments available ---
for deploy in frontend backend; do
  run_test "Deployment $deploy in develop is Available" \
    k rollout status deployment/"$deploy" -n develop --timeout=10s
done

# --- 3. Services reachable ---
# The backend Service listens on port 80 (targetPort http=8080).
# The probe pod carries app=frontend (develop is default-deny; only frontend
# and Traefik may reach the backend) and a restricted-PSS-compliant spec.
# No `--rm -i`: attaching to a pod that exits in <1s races and reports a
# timeout; create it, wait for completion, read the exit status, delete it.
# smoke_curl - true when the probe pod's curl to the backend's /healthz succeeded (waits up to 60s).
# curl retries a refused connection for up to ~10 s: a new pod's NetworkPolicy allow rules take a moment
# to apply - k3s (kube-router) refused the first second on Hetzner, kind's kindnet did not (2026-10-11).
# The pod gets a unique name, so two runs never collide and no pod of anyone else is deleted.
smoke_curl() {
  local ns="develop" pod
  pod="smoke-curl-$(date +%s)-$RANDOM"
  k run "$pod" --image=curlimages/curl:8.22.0 --labels=app=frontend --restart=Never -n "$ns" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"smoke-curl","image":"curlimages/curl:8.22.0","command":["curl","-sf","-m","10","--retry","10","--retry-delay","1","--retry-connrefused","http://backend.develop.svc.cluster.local/healthz"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
  local phase=""
  for _ in $(seq 1 30); do
    phase="$(k -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)"
    [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
    sleep 2
  done
  k -n "$ns" delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1
  [ "$phase" = "Succeeded" ]
}
run_test "Backend /healthz responds in develop" smoke_curl

# --- 3b. Every app endpoint answers on each address ---
# A dual-stack Service sends a request to any of a pod's addresses. A pod that listens on IPv4 only
# then fails every request that lands on IPv6 - through Traefik that was a 502 for about half of them
# (2026-10-16: frontend images from before frontend#26 in develop and production, while the pods were
# Ready - the kubelet probes one family). The request comes from Traefik's pod, the path visitors take,
# straight to each ready address in the EndpointSlices of frontend and backend.
# endpoints_answer NS SERVICE PATH - true when every ready pod of the Service has an address of both
# families and every address answers PATH on its pod port (from the EndpointSlice); prints what did not.
# One exec per Service.
endpoints_answer() {
  local ns="$1" svc="$2" path="$3" slices missing urls bad list u out
  slices="$(k -n "$ns" get endpointslices -l "kubernetes.io/service-name=$svc" -o json)" || return 1
  # The same ready pods in the IPv4 and the IPv6 slices: a pod missing from one family is never probed there.
  missing="$(jq -r '[.items[] | .addressType as $f | .endpoints[]? | select(.conditions.ready != false)
    | {pod: (.targetRef.name // "?"), f: $f}] | group_by(.pod)[] | select(([.[].f] | unique | length) < 2) | .[0].pod' <<< "$slices")" || return 1
  [ -z "$missing" ] || { echo "ready pods without an address of each family: $(tr '\n' ' ' <<< "$missing")"; return 1; }
  urls="$(jq -r --arg p "$path" '
    .items[] | .ports[0].port as $port | .endpoints[]? | select(.conditions.ready != false) | .addresses[]
    | if test(":") then "http://[\(.)]:\($port)\($p)" else "http://\(.):\($port)\($p)" end' <<< "$slices")" || return 1
  [ -n "$urls" ] || { echo "no ready addresses"; return 1; }
  list=()
  while IFS= read -r u; do list+=("$u"); done <<< "$urls"
  # The pod prints "done" last: without it the exec itself failed, and nothing was checked.
  # shellcheck disable=SC2016 # $u is expanded by the shell in Traefik's pod, not here
  out="$(k -n traefik exec deploy/traefik -- sh -c 'for u; do wget -q -T 5 -O /dev/null "$u" || echo " $u"; done; echo done' sh "${list[@]}" 2>/dev/null)" || true
  [ "$(tail -n 1 <<< "$out")" = "done" ] || { echo "the probe in Traefik's pod did not finish"; return 1; }
  bad="$(sed '$d' <<< "$out")"
  [ -z "$bad" ] || { echo "no answer from:$(tr -d '\n' <<< "$bad")"; return 1; }
}
# The probe itself first: a Traefik pod that cannot run wget is a probe problem, not 6 app failures.
if ! k -n traefik exec deploy/traefik -- wget --help >/dev/null 2>&1; then
  fail "Apps answer on each address - cannot run wget in Traefik's pod (kubectl exec deploy/traefik)"
else
  for ns in develop staging production; do
    for app in frontend backend; do
      path=/health; [ "$app" = backend ] && path=/healthz
      if out="$(endpoints_answer "$ns" "$app" "$path")"; then
        pass "Every $app pod in $ns answers on each address (IPv4 and IPv6)"
      else
        fail "Every $app pod in $ns answers on each address (IPv4 and IPv6) - $out"
      fi
    done
  done
fi

# --- 4. Critical secrets present ---
# (uptrace-secrets is not part of flux/secrets/develop; the DSN lives in backend-secrets)
for secret in backend-secrets app-postgres-app; do
  run_test "Secret $secret exists in develop" \
    k get secret "$secret" -n develop
done

# --- 5. Certificates valid ---
# skip NAME REASON - a check that does not apply to this cluster: counted as passed, marked # SKIP.
skip() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "ok $TOTAL - $1 # SKIP $2"
}
# certificates_ready - true when the Certificates can be listed, there is at least one and every
# one is Ready=True.
certificates_ready() {
  local states
  states="$(k get certificates.cert-manager.io -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')" || return 1
  [ -n "$states" ] || return 1
  # A here-string, not a pipe: `grep -q` stops at the first match, and with pipefail a writer killed
  # by SIGPIPE would make the pipeline fail - which `!` would turn into "healthy".
  ! grep -qvx True <<< "$states"
}
# cert-manager runs on both clusters: on Hetzner for the sites' certificates, on kind only for the
# Barman Cloud plugin's (flux/bootstrap/profiles/local/kustomization.yaml).
# Discovery must succeed first: a failing API is a failed check, not "cert-manager is not installed".
if ! api_resources="$(k api-resources -o name 2>/dev/null)"; then
  fail "cert-manager Certificate resources are Ready (API discovery failed)"
elif grep -qx 'certificates.cert-manager.io' <<< "$api_resources"; then
  run_test "cert-manager Certificate resources are Ready" certificates_ready
else
  skip "cert-manager Certificate resources are Ready" "cert-manager is not installed on this cluster"
fi

# --- 6. CNPG clusters healthy ---
# cnpg_healthy - true when the CNPG clusters can be listed, there is at least one and every one
# reports "Cluster in healthy state".
cnpg_healthy() {
  local phases
  phases="$(k get clusters.postgresql.cnpg.io -A -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}')" || return 1
  [ -n "$phases" ] || return 1
  ! grep -qvx 'Cluster in healthy state' <<< "$phases"
}
run_test "CNPG clusters are healthy" cnpg_healthy

# --- Summary ---
echo ""
echo "# Tests: $TOTAL, Pass: $PASS, Fail: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
