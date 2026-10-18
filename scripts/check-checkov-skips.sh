#!/usr/bin/env bash
# check-checkov-skips.sh - every Checkov skip in the Terraform modules is listed and has a reason.
#
# Why: `# checkov:skip=ID:reason` turns a security check off for one resource, and it is one line in a
# long diff. This check requires:
#   - a reason after the id (at least MIN_REASON characters) - a bare `checkov:skip=ID` says nothing to
#     the next reader;
#   - the set of <module> <check id> pairs in the code equals infra/terraform/checkov-skips.txt: a new
#     skip needs a second, deliberate change there, and a skip removed from the code is removed there too.
# It reads a skip the way Checkov does (checkov/common/comment/enum.py): any of the prefixes checkov:,
# bridgecrew: and cortex:skip=, spaces after "=", several ids separated by commas, the first skip of a
# line only.
# Not the global skip (CKV_TF_1 in scripts/terraform-security.sh, with its reason there).
#
# Runs in pre-commit (and with it in the CI `hooks` job). Needs only grep, sed and sort.
# Usage: scripts/check-checkov-skips.sh   (no arguments; reads infra/terraform)
# Read-only. Exit 0 when the code and the list agree and every skip has a reason, 1 otherwise.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

LIST="infra/terraform/checkov-skips.txt"
MIN_REASON=10
SKIP_PREFIX='(checkov|bridgecrew|cortex):skip='
TAB=$'\t'
failed=0

# skips_in_code - "<module> <id><TAB><file:line><TAB><reason>" for every id of every skip in a module's
# .tf files (not in .terraform/, the downloaded modules). The reason comes last: it may hold anything.
skips_in_code() {
  local hits
  hits="$(grep -rnE --include='*.tf' --exclude-dir=.terraform "${SKIP_PREFIX}" infra/terraform || true)"
  [[ -n "${hits}" ]] || return 0
  while IFS= read -r hit; do
    local where="${hit%%:*}" rest="${hit#*:}" line text module ids reason id
    line="${rest%%:*}"
    # What follows the first prefix on the line, leading spaces removed: "ID[,ID...][:reason]".
    text="$(grep -oE "${SKIP_PREFIX}.*" <<<"${hit#*:*:}" | head -n 1 | sed -E "s/^${SKIP_PREFIX} *//")"
    module="${where#infra/terraform/}"
    module="${module%%/*}"
    ids="${text%%:*}"
    ids="${ids%% *}"
    reason=""
    [[ "${text}" == *:* ]] && reason="${text#*:}"
    if [[ -z "${ids}" ]]; then
      echo "${module} (no id)${TAB}${where}:${line}${TAB}${reason}"
      continue
    fi
    for id in ${ids//,/ }; do
      echo "${module} ${id}${TAB}${where}:${line}${TAB}${reason}"
    done
  done <<<"${hits}"
}

code="$(skips_in_code)"

# A reason next to every skip.
if [[ -n "${code}" ]]; then
  while IFS="${TAB}" read -r pair where reason; do
    if (( ${#reason} < MIN_REASON )); then
      echo "check-checkov-skips: ${where}: ${pair#* } has no reason - write it after the id: checkov:skip=ID:why" >&2
      failed=1
    fi
  done <<<"${code}"
fi

# The code and the list name the same pairs (the list's lines trimmed: a stray space or CR is not a pair).
in_code="$(cut -f1 <<<"${code}" | grep . | sort -u || true)"
in_list="$(sed -E 's/[[:space:]]+$//; s/^[[:space:]]+//' "${LIST}" | grep -v -e '^#' -e '^$' | sort -u || true)"
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
