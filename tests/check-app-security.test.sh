#!/usr/bin/env bash
# Tests the service-link rule of scripts/check-app-security.sh on a throw-away copy of flux/ - no cluster.
# Run: tests/check-app-security.test.sh   (pre-commit runs it when the check or this test changes)
# Each case changes one thing in a fresh copy, runs the check and compares the verdict (pass/fail) with
# the expected one. Needs kubectl (for `kubectl kustomize`) and yq (v4), like the check.
# Exit 0 when every case passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# fresh_copy - a new copy of the check and of flux/ in WORK/repo; the check finds the repository from its
# own location, so it reads the copy.
fresh_copy() {
  rm -rf "${WORK}/repo"
  mkdir -p "${WORK}/repo/scripts"
  cp "${ROOT}/scripts/check-app-security.sh" "${WORK}/repo/scripts/"
  cp -R "${ROOT}/flux" "${WORK}/repo/"
}

# drop_field FILE - remove the enableServiceLinks line from FILE in the copy.
drop_field() {
  sed -i.bak '/enableServiceLinks:/d' "${WORK}/repo/$1" && rm -f "${WORK}/repo/$1.bak"
}

# write_file FILE CONTENT - add FILE with CONTENT to the copy.
write_file() {
  mkdir -p "$(dirname "${WORK}/repo/$1")"
  printf '%s\n' "$2" >"${WORK}/repo/$1"
}

# verdict NAME EXPECTED(pass|fail) - run the check on the current copy and compare.
verdict() {
  local got
  if "${WORK}/repo/scripts/check-app-security.sh" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [[ "${got}" == "$2" ]]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1: expected $2, got ${got}"
    FAILED=1
  fi
}

fresh_copy
verdict "the repository as it is passes" pass

fresh_copy
drop_field flux/infrastructure/data/minio/deployment.yaml
verdict "a platform Deployment without the field fails" fail

fresh_copy
drop_field flux/infrastructure/chaos/develop/cronjob.yaml
verdict "a CronJob without the field (pod spec one level deeper) fails" fail

fresh_copy
drop_field flux/apps/backend/base/deployment.yaml
verdict "an app base Deployment without the field fails" fail

fresh_copy
write_file flux/infrastructure/data/minio/patches/resources.yaml 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
spec:
  template:
    spec:
      containers:
        - name: minio
          resources:
            limits:
              memory: 512Mi'
verdict "a patch that leaves the field out passes (a partial object)" pass

fresh_copy
write_file flux/infrastructure/data/minio/patches/links.yaml 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
spec:
  template:
    spec:
      enableServiceLinks: true'
verdict "a patch file that turns it back on fails" fail

fresh_copy
write_file flux/infrastructure/inline-patch.yaml 'apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: example
spec:
  patches:
    - patch: |
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: minio
        spec:
          template:
            spec:
              enableServiceLinks: "true"'
verdict "an inline strategic-merge patch that turns it back on fails" fail

fresh_copy
write_file flux/infrastructure/inline-patch.yaml 'apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: example
spec:
  patches:
    - patch: |
        - op: replace
          path: /spec/template/spec/enableServiceLinks
          value: true
      target:
        kind: Deployment'
verdict "an inline JSON patch that turns it back on fails" fail

fresh_copy
write_file flux/infrastructure/inline-patch.yaml 'apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: example
spec:
  patches:
    - patch: |
        - op: replace
          path: /spec/template/spec/enableServiceLinks
          value: false
      target:
        kind: Deployment'
verdict "an inline JSON patch that keeps it false passes" pass

fresh_copy
write_file flux/infrastructure/broken.yaml 'kind: Deployment
  bad: ['
verdict "a YAML file yq cannot read fails the check" fail

exit "${FAILED}"
