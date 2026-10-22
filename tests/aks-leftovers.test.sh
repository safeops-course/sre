#!/usr/bin/env bash
# Tests scripts/aks-leftovers.sh against a stub az - no Azure.
# Run: tests/aks-leftovers.test.sh   (pre-commit runs it when the script or this test changes)
# The stub answers every listing empty, except the one of the cluster's group: STUB_MODE=lag names a
# resource for the first STUB_LAG calls, then nothing (Azure still listing what was just deleted);
# left names it always; fail makes that call fail. Each case checks the exit code and how many times
# that listing ran. Exit 0 when every case passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/aks-leftovers.sh"
FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/az" <<'EOF'
#!/usr/bin/env bash
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
export PATH="${WORK}/bin:${PATH}" STUB_COUNT="${WORK}/count" LEFTOVERS_WAIT=0
export TF_VAR_subscription_id=00000000-0000-0000-0000-000000000000

# case NAME WANT_RC WANT_LISTINGS MODE LAG [VAR=value...] -- ARGS... - run the script once and compare.
case_() {
  local name="$1" want_rc="$2" want_calls="$3" envs=() rc calls
  export STUB_MODE="$4" STUB_LAG="$5"
  shift 5
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  rm -f "${STUB_COUNT}"
  set +e; env "${envs[@]}" "${SCRIPT}" "$@" > "${WORK}/out.txt" 2>&1; rc=$?; set -e
  calls="$(cat "${STUB_COUNT}" 2>/dev/null || echo 0)"
  if [ "${rc}" = "${want_rc}" ] && [ "${calls}" = "${want_calls}" ]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}: exit ${rc} (want ${want_rc}), listings ${calls} (want ${want_calls})"
    sed 's/^/       /' "${WORK}/out.txt"
    FAILED=1
  fi
}

case_ "settle: Azure's lag clears on the third check"  0 3 lag 2  -- --settle sre
case_ "settle: a real leftover is still left at the end" 1 4 left 0 -- --settle sre
case_ "settle: a failed query is not retried"           2 1 fail 0 -- --settle sre
case_ "without --settle a listed resource is left"      1 1 lag 2  -- sre
case_ "nothing listed: one check, exit 0"               0 1 lag 0  -- sre
case_ "0 attempts refused (would check nothing)"        2 0 lag 0  LEFTOVERS_ATTEMPTS=0 -- --settle sre
case_ "a wait that is no number refused"                2 0 lag 0  LEFTOVERS_WAIT=x -- --settle sre
case_ "no cluster name refused"                         2 0 lag 0  -- --settle
case_ "no subscription refused"                         2 0 lag 0  TF_VAR_subscription_id= -- sre

exit "${FAILED}"
