#!/usr/bin/env bash
# Tests scripts/doks-leftovers.sh against a stub doctl - no DigitalOcean.
# Run: tests/doks-leftovers.test.sh   (pre-commit runs it when the script or this test changes)
# The stub answers every listing with an empty JSON list, except what STUB_LEFT names ("volume", "vpc"),
# and fails the listing STUB_FAIL names. STUB_LAG=N lists a volume for the first N volume listings only
# (DigitalOcean still deleting it). Like the script expects, it refuses a call without --context default or
# --output json, or with a token or context in the environment. Exit 0 when every case passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/doks-leftovers.sh"
FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/doctl" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --context default "*) ;; *) echo "stub: no --context default: $*" >&2; exit 2 ;; esac
case " $* " in *" --output json "*) ;; *) echo "stub: no --output json: $*" >&2; exit 2 ;; esac
if [ -n "${DIGITALOCEAN_ACCESS_TOKEN:-}${DIGITALOCEAN_CONTEXT:-}" ]; then echo "stub: token or context in the environment" >&2; exit 2; fi
case "$*" in
  *"volume list"*)  kind=volume ;;
  *"vpcs list"*)    kind=vpc ;;
  *"droplet list"*) kind=droplet ;;
  *) kind=other ;;
esac
if [ "${STUB_FAIL:-}" = "${kind}" ]; then echo "stub: listing failed" >&2; exit 1; fi
if [ "${kind}" = volume ] && [ -n "${STUB_LAG:-}" ]; then
  n=$(( $(cat "${STUB_COUNT}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${STUB_COUNT}"
  if [ "${n}" -le "${STUB_LAG}" ]; then echo '[{"name":"pvc-123"}]'; else echo '[]'; fi
  exit 0
fi
case "${kind}:${STUB_LEFT:-}" in
  volume:volume)  echo '[{"name":"pvc-123"}]' ;;
  vpc:vpc)        echo '[{"name":"default-fra1"},{"name":"sre-doks"}]' ;;
  vpc:*)          echo '[{"name":"default-fra1"}]' ;;
  droplet:*)      echo 'null' ;;
  *)              echo '[]' ;;
esac
EOF
chmod +x "${WORK}/bin/doctl"
touch "${WORK}/config.yaml"
# The defaults are what is tested: no LEFTOVERS_ATTEMPTS from the caller's shell; no waiting.
unset LEFTOVERS_ATTEMPTS DOCTL
export PATH="${WORK}/bin:${PATH}" DIGITALOCEAN_CONFIG="${WORK}/config.yaml" STUB_COUNT="${WORK}/count" LEFTOVERS_WAIT=0

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

case_ "nothing left (the default VPC and a null list do not count)" 0 -- sre
output "it says so"                                       has '^OK   nothing left'
case_ "a volume is left"                                  1 STUB_LEFT=volume -- sre
output "named"                                            has '^LEFT volumes: pvc-123'
case_ "the cycle's VPC is left"                           1 STUB_LEFT=vpc -- sre
output "named"                                            has '^LEFT VPC sre-doks: sre-doks'
case_ "another cluster name: its VPC is not ours"         0 STUB_LEFT=vpc -- other
case_ "a failed listing is no 'nothing left'"             2 STUB_FAIL=volume -- sre
output "named"                                            has '^FAIL could not list volumes'
case_ "a failed listing wins over a leftover"             2 STUB_LEFT=vpc STUB_FAIL=droplet -- sre
case_ "no cluster name refused"                           2 --
case_ "two names refused"                                 2 -- sre other
case_ "an unknown flag refused"                           2 -- --wait sre
case_ "--settle alone refused"                            2 -- --settle
case_ "a token in the environment is cleared"             0 DIGITALOCEAN_ACCESS_TOKEN=x DIGITALOCEAN_CONTEXT=y -- sre
case_ "settle: the volume is gone on the third check"     0 STUB_LAG=2 -- --settle sre
output "settle: a passing run prints no LEFT line"        lacks '^LEFT'
case_ "settle: a real leftover is still left at the end"  1 STUB_LEFT=volume -- --settle sre
output "settle: the last attempt prints LEFT"             has '^LEFT volumes: pvc-123'
case_ "settle: --settle after the name works too"         0 STUB_LAG=2 -- sre --settle
case_ "settle: a failed query is not retried"             2 STUB_FAIL=volume -- --settle sre
case_ "without --settle a listed volume is left"          1 STUB_LAG=2 -- sre
case_ "without --settle LEFTOVERS_ATTEMPTS is not read"   0 LEFTOVERS_ATTEMPTS=x -- sre
case_ "0 attempts refused (would check nothing)"          2 LEFTOVERS_ATTEMPTS=0 -- --settle sre
case_ "a wait that is no number refused"                  2 LEFTOVERS_WAIT=x -- --settle sre
case_ "no DIGITALOCEAN_CONFIG refused"                    2 DIGITALOCEAN_CONFIG= -- sre
case_ "a missing config file refused"                     2 DIGITALOCEAN_CONFIG=/nonexistent/config.yaml -- sre
# The Makefile passes doctl as DOCTL, a full path that need not be on PATH (2026-10-23: "doctl: command not found").
mkdir -p "${WORK}/elsewhere" && mv "${WORK}/bin/doctl" "${WORK}/elsewhere/doctl"
case_ "doctl from DOCTL, not on PATH"                     0 DOCTL="${WORK}/elsewhere/doctl" -- sre
# PATH without any directory that holds a real doctl - this case must never reach DigitalOcean.
nodoctl_path=""
IFS=: read -r -a path_dirs <<<"${PATH}"
for d in "${path_dirs[@]}"; do
  [ -x "${d}/doctl" ] || nodoctl_path="${nodoctl_path:+${nodoctl_path}:}${d}"
done
case_ "without DOCTL and doctl not on PATH: no 'nothing left'" 2 PATH="${nodoctl_path}" -- sre

exit "${FAILED}"
