#!/usr/bin/env bash
# check-credentials.sh - every credential in docs/credential-registry.yaml is described, and replaced on time.
#
# Why: a credential nobody tracks is replaced only when it leaks - in 2026-09 a CI artifact exposed
# three of them, and a runbook existed for one (Chapter 21). The registry lists each credential, every
# place a copy lives and the day it was last replaced; this check turns the dates into a failure while
# there is still time. For every entry it requires:
#   - name (unique), what, class (token | key | cluster), lives_in, used_by;
#   - runbook: FILE#anchor, a heading that exists in that file;
#   - token and key: rotated - a real date, not in the future. Due 90 (token) or 180 (key) days later;
#     the check fails WARN_DAYS before that, so there are two weeks to do it. cluster: no rotated -
#     the credential lives and dies with the cluster;
#   - expires (optional, the provider's own end date): fails WARN_DAYS before it too;
#   - exposed (optional): a value seen by someone who should not have it is due at once - fails until
#     rotated is after that day;
#   - accepted (optional) {until, reason}: holds back an overdue or exposed failure until `until`, at
#     most MAX_ACCEPT_DAYS ahead. Accepting what is not failing fails - remove it.
# And the other way round: every SOPS file under flux/secrets/ (not *.example) is named in some
# lives_in, and every flux/secrets/ path named there exists - a new Secret cannot skip the registry.
#
# Runs in pre-commit when the registry, flux/secrets/ or this check changes, and every day on main
# (.github/workflows/credential-rotation.yml): a date passes without a commit. Needs yq (v4).
# Usage: scripts/check-credentials.sh   (no arguments)
#        TODAY=2026-10-11 scripts/check-credentials.sh   (tests: a fixed "today", UTC)
# Read-only. Exit 0 when every entry passes, 1 otherwise.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

command -v yq >/dev/null || { echo "check-credentials: yq is required (make check-tools)" >&2; exit 1; }

REGISTRY="docs/credential-registry.yaml"
WARN_DAYS=14
MAX_ACCEPT_DAYS=30
TODAY="${TODAY:-$(date -u +%F)}"

# add_days DATE N - DATE + N days as YYYY-MM-DD; BSD date (macOS) and GNU date (Linux) differ here.
add_days() {
  date -u -j -v+"$2"d -f %F "$1" +%F 2>/dev/null || date -u -d "$1 + $2 days" +%F
}

# is_date VALUE - true when VALUE is YYYY-MM-DD and a real day. GNU date refuses 2026-02-30; BSD date
# rolls it over to 2026-03-02 - so the date must come back unchanged.
is_date() {
  local normalized
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  normalized="$(date -u -d "$1" +%F 2>/dev/null || date -u -j -f %F "$1" +%F 2>/dev/null || true)"
  [[ "${normalized}" == "$1" ]]
}

# anchor_of HEADING - the GitHub anchor of a Markdown heading: lower case, punctuation dropped,
# spaces to hyphens ("Hetzner API Token" -> hetzner-api-token).
anchor_of() {
  local text
  text="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  text="$(sed -E 's/[^a-z0-9 _-]//g; s/ /-/g' <<<"${text}")"
  echo "${text}"
}

# has_anchor FILE ANCHOR - true when one of FILE's headings has that anchor.
has_anchor() {
  local heading
  while IFS= read -r heading; do
    [[ "$(anchor_of "${heading}")" == "$2" ]] && return 0
  done < <(sed -nE 's/^#{1,6} +//p' "$1")
  return 1
}

[[ -f "${REGISTRY}" ]] || { echo "check-credentials: ${REGISTRY} not found" >&2; exit 1; }

SOON="$(add_days "${TODAY}" "${WARN_DAYS}")"
ACCEPT_LIMIT="$(add_days "${TODAY}" "${MAX_ACCEPT_DAYS}")"
failures=()
names=()
declared_paths=()
count="$(yq '.credentials | length' "${REGISTRY}")"
[[ "${count}" -gt 0 ]] || failures+=("${REGISTRY}: no credentials listed")

for ((i = 0; i < count; i++)); do
  field() { yq ".credentials[${i}].$1 // \"\"" "${REGISTRY}"; }
  name="$(field name)"
  where="${name:-entry ${i}}"

  # What it is, where it lives, who uses it - a credential nobody can find cannot be replaced.
  [[ -n "${name}" ]] || failures+=("${where}: name is missing")
  if [[ -n "${name}" && " ${names[*]-} " == *" ${name} "* ]]; then
    failures+=("${where}: name is used twice")
  fi
  names+=("${name}")
  for key in what used_by; do
    [[ -n "$(field "${key}")" ]] || failures+=("${where}: ${key} is missing")
  done
  [[ "$(yq ".credentials[${i}].lives_in | length" "${REGISTRY}")" -gt 0 ]] \
    || failures+=("${where}: lives_in must name every place a copy lives")
  while IFS= read -r place; do
    [[ "${place}" == flux/secrets/* ]] || continue
    path="${place%% *}"
    declared_paths+=("${path}")
    [[ -f "${path}" ]] || failures+=("${where}: lives_in names ${path}, which does not exist")
  done < <(yq ".credentials[${i}].lives_in[]" "${REGISTRY}")

  # How to replace it: a heading that exists.
  runbook="$(field runbook)"
  file="${runbook%%#*}"
  anchor="${runbook#*#}"
  if [[ -z "${runbook}" || "${runbook}" != *"#"* ]]; then
    failures+=("${where}: runbook must be FILE#anchor (got '${runbook}')")
  elif [[ ! -f "${file}" ]]; then
    failures+=("${where}: runbook file ${file} does not exist")
  elif ! has_anchor "${file}" "${anchor}"; then
    failures+=("${where}: no heading in ${file} has the anchor #${anchor}")
  fi

  # When it is due.
  class="$(field class)"
  rotated="$(field rotated)"
  expires="$(field expires)"
  exposed="$(field exposed)"
  due_now=()   # failures that an accepted entry may hold back
  case "${class}" in
    token | key)
      [[ "${class}" == token ]] && days=90 || days=180
      if ! is_date "${rotated}"; then
        failures+=("${where}: rotated must be a real date, YYYY-MM-DD (got '${rotated}')")
      elif [[ "${rotated}" > "${TODAY}" ]]; then
        failures+=("${where}: rotated ${rotated} is in the future")
      else
        due="$(add_days "${rotated}" "${days}")"
        if [[ "${due}" < "${TODAY}" ]]; then
          due_now+=("${where}: rotation overdue since ${due} (${class}: every ${days} days, last ${rotated})")
        elif [[ ! "${due}" > "${SOON}" ]]; then
          due_now+=("${where}: rotation due by ${due} (${class}: every ${days} days, last ${rotated})")
        fi
      fi
      ;;
    cluster)
      [[ -z "${rotated}" ]] || failures+=("${where}: class cluster has no rotated date - it is replaced with the cluster")
      ;;
    *)
      failures+=("${where}: class must be token, key or cluster (got '${class}')")
      ;;
  esac
  if [[ -n "${expires}" ]]; then
    if ! is_date "${expires}"; then
      failures+=("${where}: expires must be a real date, YYYY-MM-DD (got '${expires}')")
    elif [[ ! "${expires}" > "${SOON}" ]]; then
      failures+=("${where}: the provider ends it on ${expires} - replace it before then")
    fi
  fi
  if [[ -n "${exposed}" ]]; then
    if ! is_date "${exposed}" || [[ "${exposed}" > "${TODAY}" ]]; then
      failures+=("${where}: exposed must be a real date, not in the future (got '${exposed}')")
    elif [[ -z "${rotated}" || ! "${rotated}" > "${exposed}" ]]; then
      due_now+=("${where}: exposed on ${exposed} and not replaced since - due at once")
    fi
  fi

  # Debt taken on purpose: holds back due_now until a date, never for long, never for nothing.
  until="$(field accepted.until)"
  reason="$(field accepted.reason)"
  if [[ -n "$(yq ".credentials[${i}] | has(\"accepted\")" "${REGISTRY}" | grep true || true)" ]]; then
    if [[ ${#due_now[@]} -eq 0 ]]; then
      failures+=("${where}: accepted, but nothing is due - remove accepted")
    elif ! is_date "${until}" || [[ "${until}" < "${TODAY}" ]]; then
      failures+=("${due_now[@]}")
      failures+=("${where}: accepted until '${until}' - not a date, or passed")
    elif [[ "${until}" > "${ACCEPT_LIMIT}" ]]; then
      failures+=("${where}: accepted until ${until}, more than ${MAX_ACCEPT_DAYS} days ahead (latest ${ACCEPT_LIMIT})")
    elif [[ -z "${reason}" ]]; then
      failures+=("${where}: accepted needs a reason")
    else
      echo "accepted until ${until}: ${due_now[*]} (${reason})"
      due_now=()
    fi
  fi
  [[ ${#due_now[@]} -eq 0 ]] || failures+=("${due_now[@]}")
done

# Every SOPS file under flux/secrets/ is somebody's lives_in.
while IFS= read -r secret; do
  [[ " ${declared_paths[*]-} " == *" ${secret} "* ]] \
    || failures+=("${secret}: not in ${REGISTRY} - add the credential it holds")
done < <(find flux/secrets -name '*.yaml' ! -name 'kustomization.yaml' ! -name '*.example' 2>/dev/null | sort)

if [[ ${#failures[@]} -gt 0 ]]; then
  echo "check-credentials: ${#failures[@]} problem(s) (today ${TODAY}):" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi
echo "check-credentials: ${count} credential(s) OK (today ${TODAY}; nothing due before ${SOON})"
