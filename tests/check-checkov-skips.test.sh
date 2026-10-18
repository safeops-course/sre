#!/usr/bin/env bash
# Tests scripts/check-checkov-skips.sh in a throw-away copy of infra/terraform, one case at a time -
# no Checkov, no cloud. Each case changes the copy (a skip added to a .tf file, a line added to the
# list) and compares the verdict.
# Run: tests/check-checkov-skips.test.sh   (pre-commit runs it when the check or this test changes)
# Exit 0 when every case passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# run_case NAME EXPECTED(pass|fail) SETUP - a fresh copy of the check and the modules' .tf files and
# list, changed by the shell command SETUP (run inside the copy; empty: as it is); run the check; compare.
run_case() {
  local name="$1" expected="$2" setup="$3" got
  rm -rf "${WORK}/repo"
  mkdir -p "${WORK}/repo/scripts" "${WORK}/repo/infra"
  cp "${ROOT}/scripts/check-checkov-skips.sh" "${WORK}/repo/scripts/"
  # Only what the check reads: the .tf files and the list (not .terraform/, state or plans).
  (cd "${ROOT}" && find infra/terraform -name .terraform -prune -o \( -name '*.tf' -o -name checkov-skips.txt \) -print) \
    | while IFS= read -r f; do mkdir -p "${WORK}/repo/$(dirname "${f}")"; cp "${ROOT}/${f}" "${WORK}/repo/${f}"; done
  [[ -z "${setup}" ]] || (cd "${WORK}/repo" && eval "${setup}")
  if "${WORK}/repo/scripts/check-checkov-skips.sh" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [[ "${got}" == "${expected}" ]]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}: expected ${expected}, got ${got}"
    FAILED=1
  fi
}

TF="infra/terraform/gke_cluster/main.tf"
LIST="infra/terraform/checkov-skips.txt"
NEW='  # checkov:skip=CKV_GCP_99:a reason long enough to read'
run_case "the repository as it is" pass ""
run_case "a new skip, listed" pass "echo '${NEW}' >> ${TF}; echo 'gke_cluster CKV_GCP_99' >> ${LIST}"
run_case "a new skip, not listed" fail "echo '${NEW}' >> ${TF}"
run_case "a listed skip in another module than the code's" fail "echo '${NEW}' >> ${TF}; echo 'hcloud_cluster CKV_GCP_99' >> ${LIST}"
run_case "a skip without a reason" fail "echo '  # checkov:skip=CKV_GCP_99' >> ${TF}; echo 'gke_cluster CKV_GCP_99' >> ${LIST}"
run_case "a skip with an empty reason" fail "echo '  # checkov:skip=CKV_GCP_99:' >> ${TF}; echo 'gke_cluster CKV_GCP_99' >> ${LIST}"
run_case "a skip with a too short reason" fail "echo '  # checkov:skip=CKV_GCP_99:ok' >> ${TF}; echo 'gke_cluster CKV_GCP_99' >> ${LIST}"
run_case "a listed skip the code no longer has" fail "echo 'gke_cluster CKV_GCP_99' >> ${LIST}"
run_case "a skip inside a downloaded module (.terraform/) is not ours" pass \
  "mkdir -p infra/terraform/gke_cluster/.terraform/modules/x; echo '# checkov:skip=CKV_GCP_99' > infra/terraform/gke_cluster/.terraform/modules/x/main.tf"
run_case "comments and blank lines in the list" pass "printf '\n# a note\n\n' >> ${LIST}"
run_case "a stray space and CR at the end of a list line" pass "echo '${NEW}' >> ${TF}; printf 'gke_cluster CKV_GCP_99 \r\n' >> ${LIST}"
# The other prefixes Checkov accepts (checkov/common/comment/enum.py) are skips too.
run_case "bridgecrew:skip, not listed" fail "echo '  # bridgecrew:skip=CKV_GCP_99:a reason long enough to read' >> ${TF}"
run_case "cortex:skip without a reason, listed" fail "echo '  # cortex:skip=CKV_GCP_99' >> ${TF}; echo 'gke_cluster CKV_GCP_99' >> ${LIST}"
run_case "cortex:skip with a reason, listed" pass "echo '  # cortex:skip=CKV_GCP_99:a reason long enough to read' >> ${TF}; echo 'gke_cluster CKV_GCP_99' >> ${LIST}"
run_case "spaces after = (Checkov allows them), listed" pass "echo '  # checkov:skip=  CKV_GCP_99:a reason long enough to read' >> ${TF}; echo 'gke_cluster CKV_GCP_99' >> ${LIST}"
run_case "two ids in one skip, both listed" pass "echo '  # checkov:skip=CKV_GCP_98,CKV_GCP_99:a reason long enough to read' >> ${TF}; printf 'gke_cluster CKV_GCP_98\ngke_cluster CKV_GCP_99\n' >> ${LIST}"
run_case "two ids in one skip, one listed" fail "echo '  # checkov:skip=CKV_GCP_98,CKV_GCP_99:a reason long enough to read' >> ${TF}; echo 'gke_cluster CKV_GCP_99' >> ${LIST}"
run_case "a | in the reason" pass "echo '  # checkov:skip=CKV_GCP_99:a | b, a reason long enough to read' >> ${TF}; echo 'gke_cluster CKV_GCP_99' >> ${LIST}"
run_case "a skip with no id" fail "echo '  # checkov:skip=:a reason long enough to read' >> ${TF}"

exit "${FAILED}"
