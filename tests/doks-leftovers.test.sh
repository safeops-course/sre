#!/usr/bin/env bash
# Tests scripts/doks-leftovers.sh against a stub doctl - no DigitalOcean.
# Run: tests/doks-leftovers.test.sh   (pre-commit runs it when the script or this test changes)
# The stub answers every listing with an empty JSON list, except what STUB_LEFT names ("volume", "vpc",
# "other-vpc"), and fails the listing STUB_FAIL names. Like the script expects, it refuses a call without
# --context default or --output json. Exit 0 when every case passes, 1 otherwise.
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
case "$*" in
  *"volume list"*)  kind=volume ;;
  *"vpcs list"*)    kind=vpc ;;
  *"droplet list"*) kind=droplet ;;
  *) kind=other ;;
esac
if [ "${STUB_FAIL:-}" = "${kind}" ]; then echo "stub: listing failed" >&2; exit 1; fi
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
export PATH="${WORK}/bin:${PATH}" DIGITALOCEAN_CONFIG="${WORK}/config.yaml"

# case_ NAME WANT_RC [VAR=value...] -- ARGS... - run the script once and compare its exit code.
case_() {
  local name="$1" want_rc="$2" rc
  local envs=(env)
  shift 2
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
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
case_ "a flag refused"                                    2 -- --settle
case_ "no DIGITALOCEAN_CONFIG refused"                    2 DIGITALOCEAN_CONFIG= -- sre
case_ "a missing config file refused"                     2 DIGITALOCEAN_CONFIG=/nonexistent/config.yaml -- sre

exit "${FAILED}"
