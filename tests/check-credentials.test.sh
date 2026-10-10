#!/usr/bin/env bash
# Tests scripts/check-credentials.sh in a throw-away repository, one case at a time - no secrets, no
# network. Each case writes a one-entry registry (a token rotated 2026-09-01, changed by one yq edit),
# a runbook with its heading and one SOPS-looking file, runs the check with a fixed TODAY and compares
# the verdict.
# Run: tests/check-credentials.test.sh   (pre-commit runs it when the check or this test changes)
# Needs yq (v4), like the check. Exit 0 when every case passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
TODAY="2026-10-11"   # fixed: the token below is due 2026-11-30, the check fails from 2026-11-16

# run_case NAME EXPECTED(pass|fail) YQ_EDIT [SHELL_SETUP] - a fresh copy with the fixture registry,
# edited by YQ_EDIT (empty: as it is); SHELL_SETUP runs inside the copy before the check; compare.
run_case() {
  local name="$1" expected="$2" edit="$3" setup="${4:-}" got
  rm -rf "${WORK}/repo"
  mkdir -p "${WORK}/repo/scripts" "${WORK}/repo/docs" "${WORK}/repo/flux/secrets/develop"
  cp "${ROOT}/scripts/check-credentials.sh" "${WORK}/repo/scripts/"
  printf '# Runbooks\n\n## Example API Token\n\nSteps.\n' > "${WORK}/repo/docs/credential-rotation.md"
  printf 'kind: Secret\n' > "${WORK}/repo/flux/secrets/develop/example.yaml"
  printf 'resources: []\n' > "${WORK}/repo/flux/secrets/develop/kustomization.yaml"
  cat > "${WORK}/repo/docs/credential-registry.yaml" <<'EOF'
credentials:
  - name: example-token
    what: reads the example API
    class: token
    lives_in:
      - flux/secrets/develop/example.yaml (api-token)
      - GitHub organization secret EXAMPLE_TOKEN
    used_by: the example service
    rotated: 2026-09-01
    runbook: docs/credential-rotation.md#example-api-token
EOF
  [[ -z "${edit}" ]] || yq -i "${edit}" "${WORK}/repo/docs/credential-registry.yaml"
  [[ -z "${setup}" ]] || (cd "${WORK}/repo" && eval "${setup}")
  if (cd "${WORK}/repo" && TODAY="${TODAY}" scripts/check-credentials.sh >/dev/null 2>&1); then got=pass; else got=fail; fi
  if [[ "${got}" == "${expected}" ]]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}: expected ${expected}, got ${got}"
    FAILED=1
  fi
}

E='.credentials[0]'
run_case "a described token, rotated 40 days ago" pass ""
# Due dates: token 90 days, key 180; the check fails 14 days ahead.
run_case "a token due in 15 days (rotated 2026-07-28)" pass "${E}.rotated = \"2026-07-28\""
run_case "a token due in 14 days - fails, time to rotate" fail "${E}.rotated = \"2026-07-27\""
run_case "a token overdue" fail "${E}.rotated = \"2026-06-01\""
run_case "a key rotated 120 days ago (due after 180)" pass "${E}.class = \"key\" | ${E}.rotated = \"2026-06-13\""
run_case "a key overdue" fail "${E}.class = \"key\" | ${E}.rotated = \"2026-03-01\""
run_case "rotated in the future" fail "${E}.rotated = \"2026-10-12\""
run_case "rotated not a date" fail "${E}.rotated = \"last month\""
run_case "rotated an impossible date (30 February)" fail "${E}.rotated = \"2026-02-30\""
run_case "a token without rotated" fail "del(${E}.rotated)"
# class cluster: no dates of its own.
run_case "a cluster credential without rotated" pass "${E}.class = \"cluster\" | del(${E}.rotated)"
run_case "a cluster credential with rotated" fail "${E}.class = \"cluster\""
run_case "an unknown class" fail "${E}.class = \"password\""
# The provider's own end date.
run_case "expires in 30 days" pass "${E}.expires = \"2026-11-10\""
run_case "expires in 10 days" fail "${E}.expires = \"2026-10-21\""
# A leaked value is due at once - unless replaced after the leak.
run_case "exposed, not replaced since" fail "${E}.exposed = \"2026-09-20\""
run_case "exposed, replaced after" pass "${E}.exposed = \"2026-08-20\""
run_case "exposed in the future" fail "${E}.exposed = \"2026-10-20\""
# Accepted debt: only for what fails, for at most 30 days, with a reason.
run_case "exposed, accepted for 20 days with a reason" pass \
  "${E}.exposed = \"2026-09-20\" | ${E}.accepted = {\"until\": \"2026-10-31\", \"reason\": \"ingest only\"}"
run_case "accepted for 40 days" fail \
  "${E}.exposed = \"2026-09-20\" | ${E}.accepted = {\"until\": \"2026-11-20\", \"reason\": \"ingest only\"}"
run_case "accepted until yesterday" fail \
  "${E}.exposed = \"2026-09-20\" | ${E}.accepted = {\"until\": \"2026-10-10\", \"reason\": \"ingest only\"}"
run_case "accepted without a reason" fail \
  "${E}.exposed = \"2026-09-20\" | ${E}.accepted = {\"until\": \"2026-10-31\"}"
run_case "accepted, but nothing is due" fail "${E}.accepted = {\"until\": \"2026-10-31\", \"reason\": \"just in case\"}"
run_case "overdue, accepted" pass \
  "${E}.rotated = \"2026-06-01\" | ${E}.accepted = {\"until\": \"2026-10-31\", \"reason\": \"provider outage\"}"
# Described: what, where, who, how.
run_case "no what" fail "del(${E}.what)"
run_case "no used_by" fail "del(${E}.used_by)"
run_case "empty lives_in" fail "${E}.lives_in = []"
run_case "a name used twice" fail ".credentials += [.credentials[0]]"
run_case "runbook without an anchor" fail "${E}.runbook = \"docs/credential-rotation.md\""
run_case "runbook anchor with no heading" fail "${E}.runbook = \"docs/credential-rotation.md#another-token\""
run_case "runbook file missing" fail "${E}.runbook = \"docs/missing.md#example-api-token\""
# Coverage: every SOPS file is in the registry, every named file exists.
run_case "a SOPS file nobody lists" fail "" "printf 'kind: Secret\n' > flux/secrets/develop/new.yaml"
run_case "an .example template is not a credential" pass "" "printf 'kind: Secret\n' > flux/secrets/develop/new.yaml.example"
run_case "lives_in names a file that does not exist" fail "${E}.lives_in += [\"flux/secrets/staging/gone.yaml\"]"
run_case "no credentials at all" fail ".credentials = []"

exit "${FAILED}"
