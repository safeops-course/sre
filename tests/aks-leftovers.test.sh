#!/usr/bin/env bash
# Tests scripts/aks-leftovers.sh against a stub az - no Azure.
# Run: tests/aks-leftovers.test.sh   (pre-commit runs it when the script or this test changes)
# The stub answers every listing empty, except the one of the cluster's group: STUB_MODE=lag names a
# resource for the first STUB_LAG calls, then nothing (Azure still listing what was just deleted);
# left names it always; fail makes that call fail. Like the real az it refuses a call that puts
# --subscription before the command, and one without this subscription. Each case checks the exit
# code and how many times that listing ran. Exit 0 when every case passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/aks-leftovers.sh"
FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/az" <<'EOF'
#!/usr/bin/env bash
case "$1" in -*) echo "stub: az refuses options before the command: $*" >&2; exit 2 ;; esac
case " $* " in *" --subscription ${STUB_SUB} "*) ;; *) echo "stub: no --subscription ${STUB_SUB}: $*" >&2; exit 2 ;; esac
if [ "$1 $2 $3" = "resource list --resource-group" ]; then
  n=$(( $(cat "${STUB_COUNT}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${STUB_COUNT}"
  case "${STUB_MODE}" in
    lag)  if [ "${n}" -le "${STUB_LAG}" ]; then echo sre; fi ;;
    left) echo sre ;;
    fail) echo "stub: listing failed" >&2; exit 1 ;;
  esac
fi
exit 0
EOF
chmod +x "${WORK}/bin/az"
# The defaults are what is tested: no LEFTOVERS_ATTEMPTS from the caller's shell.
unset LEFTOVERS_ATTEMPTS
export PATH="${WORK}/bin:${PATH}" STUB_COUNT="${WORK}/count" LEFTOVERS_WAIT=0
export TF_VAR_subscription_id=00000000-0000-0000-0000-000000000000 STUB_SUB=00000000-0000-0000-0000-000000000000

# case_ NAME WANT_RC WANT_LISTINGS MODE LAG [VAR=value...] -- ARGS... - run the script once and compare.
# The output stays in WORK/out.txt for an output assertion that follows.
case_() {
  local name="$1" want_rc="$2" want_calls="$3" rc calls
  local envs=(env)
  export STUB_MODE="$4" STUB_LAG="$5"
  shift 5
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  rm -f "${STUB_COUNT}"
  set +e; "${envs[@]}" "${SCRIPT}" "$@" > "${WORK}/out.txt" 2>&1; rc=$?; set -e
  calls="$(cat "${STUB_COUNT}" 2>/dev/null || echo 0)"
  if [ "${rc}" = "${want_rc}" ] && [ "${calls}" = "${want_calls}" ]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}: exit ${rc} (want ${want_rc}), listings ${calls} (want ${want_calls})"
    sed 's/^/       /' "${WORK}/out.txt"
    FAILED=1
  fi
}

# output NAME has|lacks REGEX - one assertion on the last case's output (grep -E).
output() {
  local name="$1" want="$2" regex="$3" found=lacks
  if grep -qE "${regex}" "${WORK}/out.txt"; then found=has; fi
  if [ "${found}" = "${want}" ]; then echo "ok   - ${name}"; else echo "FAIL - ${name}"; sed 's/^/       /' "${WORK}/out.txt"; FAILED=1; fi
}

case_ "settle: Azure's lag clears on the third check"    0 3 lag 2  -- --settle sre
output "settle: a passing run prints no LEFT line"       lacks '^LEFT'
case_ "settle: a real leftover is still left at the end" 1 5 left 0 -- --settle sre
output "settle: the last attempt prints LEFT"            has '^LEFT resources in sre-aks: sre'
case_ "settle: --settle after the name works too"        0 3 lag 2  -- sre --settle
case_ "settle: a failed query is not retried"            2 1 fail 0 -- --settle sre
case_ "without --settle a listed resource is left"       1 1 lag 2  -- sre
case_ "nothing listed: one check, exit 0"                0 1 lag 0  -- sre
case_ "without --settle LEFTOVERS_ATTEMPTS is not read"  0 1 lag 0  LEFTOVERS_ATTEMPTS=x -- sre
case_ "0 attempts refused (would check nothing)"         2 0 lag 0  LEFTOVERS_ATTEMPTS=0 -- --settle sre
case_ "a wait that is no number refused"                 2 0 lag 0  LEFTOVERS_WAIT=x -- --settle sre
case_ "no cluster name refused"                          2 0 lag 0  -- --settle
case_ "two cluster names refused"                        2 0 lag 0  -- sre other
case_ "an unknown flag refused"                          2 0 lag 0  -- --setle sre
case_ "no subscription refused"                          2 0 lag 0  TF_VAR_subscription_id= -- sre
# Another subscription than the one the stub expects: every call refused, so the check reports a failed query.
case_ "a call the real az would refuse is a failed query" 2 0 lag 0 STUB_SUB=11111111-1111-1111-1111-111111111111 -- sre

exit "${FAILED}"
