#!/usr/bin/env bash
# Tests scripts/sks-leftovers.sh against a stub exo - no Exoscale.
# Run: tests/sks-leftovers.test.sh   (pre-commit runs it when the script or this test changes)
# The stub answers every listing with an empty JSON list, except what STUB_LEFT names ("volume", "sg"),
# and fails the listing STUB_FAIL names. STUB_LAG=N lists a volume for the first N volume listings only
# (Exoscale still deleting it). Like the script expects, it refuses a call without -O json, a zoned listing
# without the cycle's zone, or a key or account in the environment. Exit 0 when every case passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/sks-leftovers.sh"
FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/exo" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" -O json "*) ;; *) echo "stub: no -O json: $*" >&2; exit 2 ;; esac
if [ -n "${EXOSCALE_API_KEY:-}${EXOSCALE_API_SECRET:-}${EXOSCALE_ACCOUNT:-}" ]; then echo "stub: key or account in the environment" >&2; exit 2; fi
case "$*" in
  *"security-group list"*) kind=sg ;;
  *"block-storage snapshot list"*) kind=snapshot ;;
  *"block-storage list"*) kind=volume ;;
  *"instance list"*) kind=instance ;;
  *) kind=other ;;
esac
if [ "${kind}" != sg ]; then
  case " $* " in *" --zone bg-sof-1 "*) ;; *) echo "stub: not the cycle's zone: $*" >&2; exit 2 ;; esac
fi
if [ "${STUB_FAIL:-}" = "${kind}" ]; then echo "stub: listing failed" >&2; exit 1; fi
if [ "${kind}" = volume ] && [ -n "${STUB_LAG:-}" ]; then
  n=$(( $(cat "${STUB_COUNT}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${STUB_COUNT}"
  if [ "${n}" -le "${STUB_LAG}" ]; then echo '[{"name":"csi-123"}]'; else echo '[]'; fi
  exit 0
fi
case "${kind}:${STUB_LEFT:-}" in
  volume:volume)  echo '[{"name":"csi-123"}]' ;;
  sg:sg)          echo '[{"name":"default"},{"name":"sre-sks-nodes"}]' ;;
  sg:*)           echo '[{"name":"default"}]' ;;
  *)              echo '[]' ;;
esac
EOF
chmod +x "${WORK}/bin/exo"
touch "${WORK}/exoscale.toml"
# The defaults are what is tested: no LEFTOVERS_ATTEMPTS or EXO from the caller's shell; no waiting.
unset LEFTOVERS_ATTEMPTS EXO
export PATH="${WORK}/bin:${PATH}" EXOSCALE_CONFIG="${WORK}/exoscale.toml" STUB_COUNT="${WORK}/count" LEFTOVERS_WAIT=0

# case_ NAME WANT_RC [VAR=value...] -- ARGS... - run the script once and compare its exit code.
case_() {
  local name="$1" want_rc="$2" rc
  local envs=(env)
  shift 2
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  rm -f "${STUB_COUNT}"
  set +e; "${envs[@]}" "${SCRIPT}" "$@" > "${WORK}/out.txt" 2>&1; rc=$?; set -e
  if [ "${rc}" = "${want_rc}" ]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}: exit ${rc} (want ${want_rc})"
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

case_ "nothing left (the default security group does not count)" 0 -- sre bg-sof-1
output "it says so"                                       has '^OK   nothing left'
case_ "a volume is left"                                  1 STUB_LEFT=volume -- sre bg-sof-1
output "named"                                            has '^LEFT block storage volumes in bg-sof-1: csi-123'
case_ "the cycle's security group is left"                1 STUB_LEFT=sg -- sre bg-sof-1
output "named"                                            has '^LEFT security group sre-sks-nodes: sre-sks-nodes'
case_ "another cluster name: its security group is not ours" 0 STUB_LEFT=sg -- other bg-sof-1
case_ "a failed listing is no 'nothing left'"             2 STUB_FAIL=volume -- sre bg-sof-1
output "named"                                            has '^FAIL could not list block storage volumes'
case_ "a failed listing wins over a leftover"             2 STUB_LEFT=sg STUB_FAIL=instance -- sre bg-sof-1
case_ "a failed snapshot listing is no 'nothing left'"    2 STUB_FAIL=snapshot -- sre bg-sof-1
case_ "another zone is not listed (the stub refuses it)"  2 -- sre de-fra-1
case_ "no arguments refused"                              2 --
case_ "no zone refused"                                   2 -- sre
case_ "three names refused"                               2 -- sre bg-sof-1 other
case_ "an unknown flag refused"                           2 -- --wait sre bg-sof-1
case_ "--settle alone refused"                            2 -- --settle
case_ "a key or account in the environment is cleared"    0 EXOSCALE_API_KEY=x EXOSCALE_API_SECRET=y EXOSCALE_ACCOUNT=z -- sre bg-sof-1
case_ "settle: the volume is gone on the third check"     0 STUB_LAG=2 -- --settle sre bg-sof-1
output "settle: a passing run prints no LEFT line"        lacks '^LEFT'
case_ "settle: a real leftover is still left at the end"  1 STUB_LEFT=volume -- --settle sre bg-sof-1
output "settle: the last attempt prints LEFT"             has '^LEFT block storage volumes in bg-sof-1: csi-123'
case_ "settle: --settle after the names works too"        0 STUB_LAG=2 -- sre bg-sof-1 --settle
case_ "settle: a failed query is not retried"             2 STUB_FAIL=volume -- --settle sre bg-sof-1
case_ "without --settle a listed volume is left"          1 STUB_LAG=2 -- sre bg-sof-1
case_ "without --settle LEFTOVERS_ATTEMPTS is not read"   0 LEFTOVERS_ATTEMPTS=x -- sre bg-sof-1
case_ "0 attempts refused (would check nothing)"          2 LEFTOVERS_ATTEMPTS=0 -- --settle sre bg-sof-1
case_ "a wait that is no number refused"                  2 LEFTOVERS_WAIT=x -- --settle sre bg-sof-1
case_ "no EXOSCALE_CONFIG refused"                        2 EXOSCALE_CONFIG= -- sre bg-sof-1
case_ "a missing config file refused"                     2 EXOSCALE_CONFIG=/nonexistent/exoscale.toml -- sre bg-sof-1
# The Makefile passes exo as EXO, a full path that need not be on PATH (as doctl on DOKS, 2026-10-23).
mkdir -p "${WORK}/elsewhere" && mv "${WORK}/bin/exo" "${WORK}/elsewhere/exo"
case_ "exo from EXO, not on PATH"                         0 EXO="${WORK}/elsewhere/exo" -- sre bg-sof-1
# PATH without any directory that holds a real exo - this case must never reach Exoscale.
noexo_path=""
IFS=: read -r -a path_dirs <<<"${PATH}"
for d in "${path_dirs[@]}"; do
  [ -x "${d}/exo" ] || noexo_path="${noexo_path:+${noexo_path}:}${d}"
done
case_ "without EXO and exo not on PATH: no 'nothing left'" 2 PATH="${noexo_path}" -- sre bg-sof-1

exit "${FAILED}"
