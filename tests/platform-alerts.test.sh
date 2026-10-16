#!/usr/bin/env bash
# Unit test for the platform alerts (flux/infrastructure/observability/kube-prometheus-stack/
# monitoring/platform-alerts.yaml) and the canary alerts of Chapter 19
# (flux/infrastructure/progressive-delivery/develop/alerts.yaml): promtool evaluates the rules against made-up series in
# tests/platform-alerts/tests.yaml and fails when an alert fires where it should not, or stays
# silent where it should fire - the restart loop that exits 0, the component that keeps a core busy.
#
# Every other PrometheusRule under flux/ gets `promtool check rules` too: the API server stores a rule
# without parsing its PromQL, so a typo would reach Prometheus unnoticed (only two files were checked
# before 2026-10-16).
#
# Runs in pre-commit and CI; no cluster, no network. Needs promtool (make check-tools) and yq (v4).
# A PrometheusRule is a Kubernetes object; promtool wants plain rules files, so each spec is
# extracted into a temporary directory first.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# rules file name (as tests.yaml lists it) and the PrometheusRule it comes from.
rules=(
  "platform.yaml ${repo_root}/flux/infrastructure/observability/kube-prometheus-stack/monitoring/platform-alerts.yaml"
  "progressive-delivery.yaml ${repo_root}/flux/infrastructure/progressive-delivery/develop/alerts.yaml"
)
tests="${repo_root}/tests/platform-alerts/tests.yaml"

for tool in promtool yq; do
  command -v "${tool}" >/dev/null || { echo "platform-alerts: ${tool} is required (make check-tools)" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The two the unit tests name (promtool test rules parses them below).
for entry in "${rules[@]}"; do
  read -r name source <<<"${entry}"
  yq '.spec' "${source}" > "${work}/${name}"
done

# Every PrometheusRule under flux/, found by its kind (yq, not a text search: a quoted or indented
# kind counts too), one document at a time - promtool reads only the first document of a file. A new
# rules file is checked without a list to keep up to date.
pairs="$(find "${repo_root}/flux" -name '*.yaml' -print0 \
  | xargs -0 yq -N 'select(tag == "!!map" and .kind == "PrometheusRule") | filename + " " + .metadata.name')"
# None found is a broken search, not a clean result.
[ -n "${pairs}" ] || { echo "platform-alerts: no PrometheusRule found under flux/" >&2; exit 1; }
n=0
while read -r source name; do
  n=$((n + 1))
  echo "platform-alerts: ${source#"${repo_root}/"} - ${name}"
  yq "select(.kind == \"PrometheusRule\" and .metadata.name == \"${name}\") | .spec" "${source}" > "${work}/rule-${n}.yaml"
  promtool check rules "${work}/rule-${n}.yaml"
done <<<"${pairs}"
cp "${tests}" "${work}/tests.yaml"
promtool test rules "${work}/tests.yaml"
