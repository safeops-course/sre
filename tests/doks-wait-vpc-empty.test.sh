#!/usr/bin/env bash
# Tests infra/terraform/scripts/doks-wait-vpc-empty.sh against a stub doctl - no DigitalOcean.
# Run: tests/doks-wait-vpc-empty.test.sh   (pre-commit runs it when the script or this test changes)
# The stub lists one droplet in VPC "vpc-1" for the first STUB_LAG droplet listings, then none; a load
# balancer in "vpc-1" when STUB_LB=1; one droplet in another VPC always; STUB_FAIL=droplet fails the
# droplet listing. It refuses a call without --context default or --output json, or with a token in the
# environment. Exit 0 when every case passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/infra/terraform/scripts/doks-wait-vpc-empty.sh"
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
  *"droplet list"*)
    if [ "${STUB_FAIL:-}" = droplet ]; then echo "stub: listing failed" >&2; exit 1; fi
    n=$(( $(cat "${STUB_COUNT}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${STUB_COUNT}"
    if [ "${n}" -le "${STUB_LAG:-0}" ]; then
      echo '[{"name":"platform-1","vpc_uuid":"vpc-1"},{"name":"other","vpc_uuid":"vpc-2"}]'
    else
      echo '[{"name":"other","vpc_uuid":"vpc-2"}]'
    fi ;;
  *"load-balancer list"*)
    if [ "${STUB_LB:-}" = 1 ]; then echo '[{"name":"sre-doks-traefik","vpc_uuid":"vpc-1"}]'; else echo '[]'; fi ;;
  *) echo "stub: unexpected call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "${WORK}/bin/doctl"
# No real sleeping: the script waits 15 s between checks.
cat > "${WORK}/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${WORK}/bin/sleep"
export PATH="${WORK}/bin:${PATH}" STUB_COUNT="${WORK}/count"

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

case_ "empty at once (another VPC's droplet does not count)" 0 -- vpc-1
output "it says so"                                       has 'has no members after 0 s'
case_ "a node still deleting: empty on the third check"   0 STUB_LAG=2 -- vpc-1
output "it named the node while waiting"                  has 'waiting for: droplet platform-1'
case_ "still a member at the timeout"                     1 STUB_LAG=99 VPC_WAIT_TIMEOUT=30 -- vpc-1
output "named"                                            has 'still in VPC vpc-1 after 30 s: droplet platform-1'
case_ "a load balancer is a member too"                   1 STUB_LB=1 VPC_WAIT_TIMEOUT=0 -- vpc-1
case_ "a failed listing is no 'empty'"                    2 STUB_FAIL=droplet -- vpc-1
case_ "a token in the environment is cleared"             0 DIGITALOCEAN_ACCESS_TOKEN=x -- vpc-1
case_ "no VPC id refused"                                 2 --
case_ "a timeout that is no number refused"               2 VPC_WAIT_TIMEOUT=x -- vpc-1
mkdir -p "${WORK}/elsewhere" && mv "${WORK}/bin/doctl" "${WORK}/elsewhere/doctl"
case_ "doctl from DOCTL, not on PATH"                     0 DOCTL="${WORK}/elsewhere/doctl" -- vpc-1

exit "${FAILED}"
