#!/usr/bin/env bash
# check-checkov-skips.sh - every Checkov skip in the Terraform modules is listed and has a reason.
#
# Why: `# checkov:skip=ID:reason` turns a security check off for one resource, and it is one line in a
# long diff. This check requires:
#   - a reason after the id (at least MIN_REASON characters) - a bare `checkov:skip=ID` says nothing to
#     the next reader;
#   - the set of <module> <check id> pairs in the code equals infra/terraform/checkov-skips.txt: a new
#     skip needs a second, deliberate change there, and a skip removed from the code is removed there too.
# Not the global skip (CKV_TF_1 in scripts/terraform-security.sh, with its reason there).
#
# Runs in pre-commit (and with it in the CI `hooks` job). Needs only grep and sort.
# Usage: scripts/check-checkov-skips.sh   (no arguments; reads infra/terraform)
# Read-only. Exit 0 when the code and the list agree and every skip has a reason, 1 otherwise.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

LIST="infra/terraform/checkov-skips.txt"
MIN_REASON=10
failed=0

# skips_in_code - "<module> <id>|<reason>|<file:line>" for every checkov:skip in a module's .tf files
# (not in .terraform/, the downloaded modules).
skips_in_code() {
  local hits
  hits="$(grep -rn --include='*.tf' --exclude-dir=.terraform 'checkov:skip=' infra/terraform || true)"
  [[ -n "${hits}" ]] || return 0
  while IFS= read -r hit; do
    local where="${hit%%:*}" rest="${hit#*:}" line text module id reason
    line="${rest%%:*}"
    text="${rest#*checkov:skip=}"
    module="${where#infra/terraform/}"
    module="${module%%/*}"
    id="${text%%:*}"
    id="${id%% *}"
    reason=""
    [[ "${text}" == *:* ]] && reason="${text#*:}"
    echo "${module} ${id}|${reason}|${where}:${line}"
  done <<<"${hits}"
}

code="$(skips_in_code)"

# A reason next to every skip.
if [[ -n "${code}" ]]; then
  while IFS='|' read -r pair reason where; do
    if (( ${#reason} < MIN_REASON )); then
      echo "check-checkov-skips: ${where}: ${pair#* } has no reason - write it after the id: checkov:skip=ID:why" >&2
      failed=1
    fi
  done <<<"${code}"
fi

# The code and the list name the same pairs.
in_code="$(cut -d'|' -f1 <<<"${code}" | grep . | sort -u || true)"
in_list="$(grep -v -e '^#' -e '^[[:space:]]*$' "${LIST}" | sort -u || true)"
missing_from_list="$(comm -23 <(echo "${in_code}") <(echo "${in_list}") | grep . || true)"
stale_in_list="$(comm -13 <(echo "${in_code}") <(echo "${in_list}") | grep . || true)"
if [[ -n "${missing_from_list}" ]]; then
  echo "check-checkov-skips: skipped in the code, not in ${LIST} - add the line if the skip is meant:" >&2
  while IFS= read -r l; do echo "  ${l}" >&2; done <<<"${missing_from_list}"
  failed=1
fi
if [[ -n "${stale_in_list}" ]]; then
  echo "check-checkov-skips: in ${LIST}, no longer skipped in the code - remove the line:" >&2
  while IFS= read -r l; do echo "  ${l}" >&2; done <<<"${stale_in_list}"
  failed=1
fi

if (( failed == 0 )); then
  echo "check-checkov-skips: $(grep -c . <<<"${in_code}" || true) skips, each listed and with a reason"
fi
exit "${failed}"
