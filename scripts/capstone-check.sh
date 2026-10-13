#!/usr/bin/env bash
# capstone-check.sh - the Chapter 23 capstone's acceptance criteria, each checked against Git and the
# running cluster.
#
# Why: "it works" is a claim; each criterion here is a state anyone can check again. The capstone
# asks for display names in staging and production (Chapter 18's flag), a colleague's breaking change
# (make capstone-fault) fixed through Git, no shortcut that switched a guardrail off, a platform that
# passes its smoke test, and a handover in the repository. For each criterion the script prints
# PROVEN or NOT PROVEN YET, with what is missing and where to look. The third level of the chapter's
# grading - proven with a hint - is yours to record in the handover: the script cannot know.
# What it does not check: the proof on the users' path (a sign-up and a sign-in, each with its time)
# - that evidence goes into the handover, from your own requests.
#
# Usage: make capstone-check
#        KUBE_CONTEXT=<context> scripts/capstone-check.sh   (default: kind-sre-control-plane)
# Needs git, kubectl, flux, jq and an origin remote. Changes nothing, except `git fetch origin main`
# and the smoke test's short-lived probe pod (tests/smoke-test.sh).
# Exit 0 when every criterion is proven, 1 otherwise, 2 when the context is missing or does not answer.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

KUBE_CONTEXT="${KUBE_CONTEXT:-kind-sre-control-plane}"
if ! kubectl config get-contexts "${KUBE_CONTEXT}" >/dev/null 2>&1; then
  echo "capstone-check: context '${KUBE_CONTEXT}' not found in the kubeconfig" >&2
  exit 2
fi
if ! kubectl --context "${KUBE_CONTEXT}" get --raw /readyz >/dev/null 2>&1; then
  echo "capstone-check: the API server of '${KUBE_CONTEXT}' does not answer - is the cluster running?" >&2
  exit 2
fi

# k ARGS... - kubectl against KUBE_CONTEXT; the only way this script reads the cluster.
k() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

# The first backend release that passes FEATURE_DISPLAY_NAME to the server: its tag's timestamp
# (Chapter 18, A4 - "flag fix"). An older release ignores the flag whatever the pods' environment says.
FLAG_FIX_TIMESTAMP=1791462208
# The colleague's change undone: the values main had before it. More is fine; less is the fault.
MIN_REGISTRATIONS_PER_MINUTE=10   # the backend's default
ENVIRONMENTS=(develop staging production)
# The platform's admission policies that deny (Chapters 16 and 17, flux/infrastructure/policy/packs/).
# A new policy pack adds its *-enforce policy here.
ENFORCING_POLICIES=(disallow-latest-tag-enforce disallow-privileged-containers-enforce
  require-requests-limits-enforce require-security-context-enforce require-trusted-registries-enforce
  verify-images-enforce)

PROBLEMS=()   # what the current criterion found missing - filled by the check_* functions
PROVEN=0
TOTAL=0

# problem TEXT - record one thing the current criterion is missing.
problem() { PROBLEMS+=("$1"); }

# criterion NAME HINT CHECK_FUNCTION - run one criterion and print its verdict; on NOT PROVEN YET
# also what is missing and the hint.
# The check runs in a subshell with set -e, so a failed read (an object that is gone, the API server
# busy) ends only that check - as a problem, never as a PROVEN from an empty answer - and every other
# criterion still prints its verdict. set -e is ignored inside an if or ||, hence the set +e around it.
criterion() {
  local name="$1" hint="$2" check="$3" p output rc
  PROBLEMS=()
  TOTAL=$((TOTAL + 1))
  set +e
  output="$(set -e; "${check}"; for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do echo "${p}"; done)"
  rc=$?
  set -e
  if [[ -n "${output}" ]]; then
    while IFS= read -r p; do PROBLEMS+=("${p}"); done <<<"${output}"
  fi
  [[ "${rc}" -eq 0 ]] || problem "a read from the cluster or Git failed (exit ${rc}, the error above) - run it again"
  if [[ ${#PROBLEMS[@]} -eq 0 ]]; then
    PROVEN=$((PROVEN + 1))
    printf '  %-15s %d. %s\n' "PROVEN" "${TOTAL}" "${name}"
  else
    printf '  %-15s %d. %s\n' "NOT PROVEN YET" "${TOTAL}" "${name}"
    for p in "${PROBLEMS[@]}"; do printf '%20s- %s\n' "" "${p}"; done
    printf '%20shint: %s\n' "" "${hint}"
  fi
}

# min_cpu ENV - main's backend CPU in ENV, in millicores: "<request> <limit>". Develop runs smaller
# (its overlay patches its own); staging and production get the base.
min_cpu() {
  case "$1" in
    develop) echo "50 200" ;;
    *) echo "100 250" ;;
  esac
}

# millicores QUANTITY - a CPU quantity (250m, 0.5, 1) in millicores; empty when there is none.
millicores() {
  local q="$1"
  case "${q}" in
    "") echo "" ;;
    *m) echo "${q%m}" ;;
    *) awk -v q="${q}" 'BEGIN { printf "%d\n", q * 1000 }' ;;
  esac
}

# backend_json ENV - the backend container of ENV's Deployment, as JSON.
backend_json() {
  k -n "$1" get deployment backend -o json | jq '.spec.template.spec.containers[] | select(.name == "backend")'
}

# flag_value ENV NAME - the value the backend's pods get for the variable NAME: env first, then the
# ConfigMaps in envFrom (Kubernetes gives env precedence). Empty when it is not set.
flag_value() {
  local env="$1" name="$2" container value cm
  container="$(backend_json "${env}")"
  value="$(jq -r --arg n "${name}" '(.env // [])[] | select(.name == $n) | .value // ""' <<<"${container}")"
  if [[ -n "${value}" ]]; then echo "${value}"; return; fi
  for cm in $(jq -r '(.envFrom // [])[] | .configMapRef.name // empty' <<<"${container}"); do
    value="$(k -n "${env}" get configmap "${cm}" -o json | jq -r --arg n "${name}" '.data[$n] // ""')"
    if [[ -n "${value}" ]]; then echo "${value}"; return; fi
  done
}

# selector_string SELECTOR_JSON - a label selector (matchLabels, matchExpressions) as the string
# kubectl -l takes. Empty for an empty selector, which selects every pod.
selector_string() {
  jq -r '[ ((.matchLabels // {}) | to_entries[] | "\(.key)=\(.value)"),
           ((.matchExpressions // [])[] |
             if .operator == "In" then "\(.key) in (\(.values | join(",")))"
             elif .operator == "NotIn" then "\(.key) notin (\(.values | join(",")))"
             elif .operator == "Exists" then .key
             else "!\(.key)" end) ] | join(",")' <<<"$1"
}

# pods_selected ENV SELECTOR_JSON - the names of ENV's pods the selector selects, one per line.
pods_selected() {
  local selector
  selector="$(selector_string "$2")"
  if [[ -z "${selector}" ]]; then
    k -n "$1" get pods -o name
  else
    k -n "$1" get pods -l "${selector}" -o name
  fi
}

# --- the criteria ---

# check_delivery - Flux has applied origin/main: the source's revision and every Kustomization's, all
# Ready, none suspended.
check_delivery() {
  local source_rev rows
  source_rev="$(k -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}')"
  [[ "${source_rev}" == *"${MAIN}"* ]] \
    || problem "the flux-system source is at ${source_rev:-nothing}, not origin/main (${MAIN:0:7})"
  rows="$(k get kustomizations -A -o json | jq -r --arg main "${MAIN}" '.items[]
    | select(.spec.suspend == true
        or ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 0
        or ((.status.lastAppliedRevision // "") | contains($main) | not))
    | "\(.metadata.namespace)/\(.metadata.name): " + (if .spec.suspend == true then "suspended" else "not Ready on origin/main" end)')"
  if [[ -n "${rows}" ]]; then
    while IFS= read -r row; do problem "Kustomization ${row}"; done <<<"${rows}"
  fi
}

# check_display_names ENV - in ENV the rollout is complete, the pods get FEATURE_DISPLAY_NAME=true and
# run a release that reads it.
check_display_names() {
  local env="$1" status value image timestamp
  status="$(k -n "${env}" get deployment backend -o json | jq -r '
    if .status.observedGeneration == .metadata.generation
       and (.status.updatedReplicas // 0) == .status.replicas
       and (.status.readyReplicas // 0) == .status.replicas
       and (.status.unavailableReplicas // 0) == 0
    then "complete" else "\(.status.updatedReplicas // 0) updated, \(.status.readyReplicas // 0) ready of \(.status.replicas // 0)" end')"
  [[ "${status}" == "complete" ]] || problem "the backend rollout is not complete: ${status}"
  value="$(flag_value "${env}" FEATURE_DISPLAY_NAME)"
  [[ "${value}" == "true" ]] || problem "the backend pods get FEATURE_DISPLAY_NAME=\"${value}\", not \"true\""
  image="$(backend_json "${env}" | jq -r '.image')"
  timestamp="${image##*-}"
  if ! [[ "${timestamp}" =~ ^[0-9]+$ ]] || (( timestamp < FLAG_FIX_TIMESTAMP )); then
    problem "the release ${image##*:} is older than the flag fix - it ignores the flag"
  fi
}
check_display_names_staging() { check_display_names staging; }
check_display_names_production() { check_display_names production; }

# check_colleague_change - none of the colleague's three possible changes is in the cluster: sign-ups
# not limited below the default, the database policies select the database pods, backend CPU not
# below main's values. Every environment.
# It names only the environments, never what is wrong in them: the script may run any time, and a
# verdict that named the setting would hand over the diagnosis the capstone asks for.
check_colleague_change() {
  local env value container request limit min_request min_limit postgres selected selected_in policy pod
  local affected=()
  for env in "${ENVIRONMENTS[@]}"; do
    local broken=0
    value="$(flag_value "${env}" AUTH_REGISTRATIONS_PER_MINUTE)"
    if [[ -n "${value}" ]] && ! { [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= MIN_REGISTRATIONS_PER_MINUTE )); }; then
      broken=1
    fi

    container="$(backend_json "${env}")"
    request="$(millicores "$(jq -r '.resources.requests.cpu // ""' <<<"${container}")")"
    limit="$(millicores "$(jq -r '.resources.limits.cpu // ""' <<<"${container}")")"
    read -r min_request min_limit <<<"$(min_cpu "${env}")"
    if [[ -z "${request}" ]] || (( request < min_request )) || [[ -z "${limit}" ]] || (( limit < min_limit )); then
      broken=1
    fi

    postgres="$(k -n "${env}" get pods -l cnpg.io/cluster=app-postgres -o name)"
    if [[ -z "${postgres}" ]]; then
      problem "${env}: no database pods (cnpg.io/cluster=app-postgres) to check against"
      (( broken == 0 )) || affected+=("${env}")   # what was found before still counts
      continue
    fi
    # The backend's way out: the egress policy's destinations must include every database pod;
    # the database's way in: the ingress policy must apply to every database pod. A missing policy
    # counts as broken too.
    if policy="$(k -n "${env}" get networkpolicy allow-backend-egress-postgres -o json 2>/dev/null)"; then
      selected="$(jq -c '.spec.egress[].to[] | .podSelector // empty' <<<"${policy}" \
        | while IFS= read -r s; do pods_selected "${env}" "${s}"; done)"
    else
      selected=""
    fi
    if policy="$(k -n "${env}" get networkpolicy allow-postgres-ingress-backend -o json 2>/dev/null)"; then
      selected_in="$(pods_selected "${env}" "$(jq -c '.spec.podSelector' <<<"${policy}")")"
    else
      selected_in=""
    fi
    for pod in ${postgres}; do
      grep -qx "${pod}" <<<"${selected}" || broken=1
      grep -qx "${pod}" <<<"${selected_in}" || broken=1
    done
    (( broken == 0 )) || affected+=("${env}")
  done
  if [[ ${#affected[@]} -gt 0 ]]; then
    problem "not as main had it before the colleague's change, in: ${affected[*]}"
  fi
}

# check_no_shortcut - the guardrails are still on, now: no PolicyException in the cluster; each of the
# platform's admission policies that deny (ENFORCING_POLICIES) is there and still denies;
# default-deny-all, with no rule that allows anything, in every application namespace; and every
# egress rule there names its destinations and ports. It checks the state, not the way there - a guardrail switched off and on
# again, or a rule wider than its one path, is for the handover and the git log.
check_no_shortcut() {
  local exceptions policies name actions env open deny
  exceptions="$(k get policyexceptions.policies.kyverno.io -A -o name)"
  [[ -z "${exceptions}" ]] || problem "PolicyException in the cluster: ${exceptions//$'\n'/, }"
  policies="$(k get validatingpolicies.policies.kyverno.io,imagevalidatingpolicies.policies.kyverno.io -o json)"
  for name in "${ENFORCING_POLICIES[@]}"; do
    actions="$(jq -r --arg n "${name}" '[.items[] | select(.metadata.name == $n)][0].spec.validationActions // [] | join(",")' <<<"${policies}")"
    [[ ",${actions}," == *",Deny,"* ]] || problem "admission policy ${name} is gone or no longer denies (${actions:-gone})"
  done
  for env in "${ENVIRONMENTS[@]}"; do
    deny="$(k -n "${env}" get networkpolicy -o json | jq -r '[.items[] | select(.metadata.name == "default-deny-all"
      and .spec.podSelector == {} and (.spec.policyTypes | index("Ingress")) and (.spec.policyTypes | index("Egress"))
      and ((.spec.ingress // []) | length) == 0 and ((.spec.egress // []) | length) == 0)] | length')"
    (( deny == 1 )) || problem "${env}: no default-deny-all for ingress and egress of every pod"
    open="$(k -n "${env}" get networkpolicy -o json | jq -r '.items[]
      | select([(.spec.egress // [])[] | select((.to | not) or (.ports | not))] | length > 0)
      | .metadata.name')"
    [[ -z "${open}" ]] || problem "${env}: egress open to any destination or port in ${open//$'\n'/, }"
  done
}

# check_smoke_test - the platform's own baseline check passes (tests/smoke-test.sh).
check_smoke_test() {
  KUBE_CONTEXT="${KUBE_CONTEXT}" bash tests/smoke-test.sh >/dev/null 2>&1 \
    || problem "make smoke-test fails"
}

# check_handover - docs/handover.md is on main, every TODO of the template replaced.
check_handover() {
  local text
  if ! text="$(git show "origin/main:docs/handover.md" 2>/dev/null)"; then
    problem "no docs/handover.md on origin/main"
    return
  fi
  if grep -q 'TODO' <<<"${text}"; then
    problem "docs/handover.md still has $(grep -c 'TODO' <<<"${text}") TODO line(s)"
  fi
}

git fetch -q origin main
MAIN="$(git rev-parse origin/main)"
echo "Chapter 23 capstone check - cluster ${KUBE_CONTEXT}, origin/main ${MAIN:0:7}"
echo

criterion "Flux applies origin/main, every Kustomization Ready" \
  "Chapter 03: flux get kustomizations; a change counts once it is merged and applied" check_delivery
criterion "Display names in staging" \
  "Chapter 18, B3: the flag through Git, the rollout, then a sign-in that returns display_name" check_display_names_staging
criterion "Display names in production" \
  "the same as staging, after staging is proven - and only then" check_display_names_production
criterion "The colleague's change is fixed, in every environment" \
  "git log on main: what changed since you started? Prove the cause by its symptom, fix it with a pull request" check_colleague_change
criterion "No guardrail switched off on the way" \
  "Chapters 06 and 16: a fix opens only what is needed - remove the shortcut through Git" check_no_shortcut
criterion "The smoke test passes" \
  "make smoke-test shows which check fails" check_smoke_test
criterion "The handover is in Git" \
  "cp docs/handover-template.md docs/handover.md, replace every TODO placeholder, merge it" check_handover

echo
echo "${PROVEN} of ${TOTAL} proven."
[[ "${PROVEN}" -eq "${TOTAL}" ]]
