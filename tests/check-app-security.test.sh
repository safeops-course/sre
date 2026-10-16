#!/usr/bin/env bash
# Tests the service-link rule and the IPv4/IPv6 NetworkPolicy rule of scripts/check-app-security.sh on
# throw-away copies of flux/ - no cluster.
# Run: tests/check-app-security.test.sh   (pre-commit runs it when the check or this test changes)
# Each case changes one thing in its own copy, runs the check and compares the verdict (pass/fail) with
# the expected one. The check builds what Flux would apply (flux build, from the profiles), so every
# patch below is wired in the way Flux reaches it: listed in MinIO's kustomization.yaml (the local
# profile deploys MinIO), or added to a Flux Kustomization's spec.patches by the local profile.
# A failing case must fail on the rule itself ("must be the boolean false"), not on a build error.
# The cases run in parallel, one per CPU (each check builds ~66 Flux Kustomizations). Needs kubectl, yq (v4), jq and
# the flux CLI, like the check. Exit 0 when every case passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
MINIO=flux/infrastructure/data/minio
PROFILE=flux/bootstrap/profiles/local/kustomization.yaml
TARGET='target: {kind: Deployment, name: minio}'
RULE='must be the boolean false'

# --- helpers; R is the copy of the repository the current case works in ---

# fresh_copy - the check and flux/ copied into R; the check finds the repository from its own location.
fresh_copy() {
  mkdir -p "${R}/scripts"
  cp "${ROOT}/scripts/check-app-security.sh" "${R}/scripts/"
  cp -R "${ROOT}/flux" "${R}/"
}

# drop_field FILE - remove the enableServiceLinks line from FILE.
drop_field() {
  sed -i.bak '/enableServiceLinks:/d' "${R}/$1" && rm -f "${R}/$1.bak"
}

# write_file FILE CONTENT - add FILE with CONTENT.
write_file() {
  mkdir -p "$(dirname "${R}/$1")"
  printf '%s\n' "$2" >"${R}/$1"
}

# minio_patch ENTRY - append ENTRY (a YAML map: path or patch, optional target) to the patches of
# MinIO's kustomization.yaml.
minio_patch() {
  ENTRY="$1" yq -i '.patches += [env(ENTRY)]' "${R}/${MINIO}/kustomization.yaml"
}

# smp VALUE - a strategic-merge patch for the MinIO Deployment that sets the field to VALUE (as written).
smp() {
  printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: minio\n  namespace: minio\nspec:\n  template:\n    spec:\n      enableServiceLinks: %s\n' "$1"
}

# indent N TEXT - TEXT with every line indented by N spaces (to nest a patch in a block scalar).
indent() {
  local pad
  pad="$(printf '%*s' "$1" '')"
  printf '%s\n' "$2" | sed "s/^/${pad}/"
}

# profile_patch KUSTOMIZATION PATCHES - the local profile gives the Flux Kustomization KUSTOMIZATION the
# spec.patches PATCHES (a YAML list), the way the profiles do: Flux applies them, kustomize does not.
profile_patch() {
  KS="$1" PATCHES="$2" yq -i '.patches += [{"target": {"kind": "Kustomization", "name": strenv(KS)},
      "patch": ([{"op": "add", "path": "/spec/patches", "value": env(PATCHES)}] | to_yaml)}]' "${R}/${PROFILE}"
}

# --- the cases: the setup of each, one function per case (CASES below names them) ---

# links_file VALUE - a patch file listed in MinIO's kustomization.yaml that sets the field to VALUE.
links_file() { write_file "${MINIO}/patches/links.yaml" "$(smp "$1")"; minio_patch 'path: patches/links.yaml'; }

case_01() {
  :
}
case_02() {
  drop_field "${MINIO}/deployment.yaml"
}
case_03() {
  drop_field flux/infrastructure/chaos/develop/cronjob.yaml
}
case_04() {
  drop_field flux/apps/backend/base/deployment.yaml
}
case_05() {
  write_file "${MINIO}/patches/memory.yaml" 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  template:
    spec:
      containers:
        - name: minio
          resources:
            limits:
              memory: 512Mi'
  minio_patch 'path: patches/memory.yaml'
}
case_06() {
  links_file true
}
case_07() {
  links_file TRUE
}
case_08() {
  links_file True
}
case_09() {
  links_file yes
}
case_10() {
  links_file '"false"'
}
case_11() {
  links_file false
}
case_12() {
  write_file "${MINIO}/patches/replace.yaml" 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  template:
    spec:
      $patch: replace
      containers:
        - name: minio
          image: minio'
  minio_patch 'path: patches/replace.yaml'
}
case_13() {
  minio_patch "patch: |-
$(indent 2 "$(smp false)")
  ---
  apiVersion: batch/v1
  kind: Job
  metadata:
    name: minio-create-bucket
    namespace: minio
  spec:
    template:
      spec:
        enableServiceLinks: TRUE"
}
case_14() {
  minio_patch "patch: |-
  - op: remove
    path: /spec/template/spec/enableServiceLinks
${TARGET}"
}
case_15() {
  minio_patch "patch: |-
  - op: move
    from: /spec/template/spec/enableServiceLinks
    path: /spec/template/spec/hostname
${TARGET}"
}
case_16() {
  write_file "${MINIO}/patches/json.yaml" '- op: replace
  path: /spec/template/spec/enableServiceLinks
  value: true'
  minio_patch "path: patches/json.yaml
${TARGET}"
}
case_17() {
  minio_patch "patch: |-
  - op: replace
    path: /spec/template/spec
    value:
      containers: [{name: minio, image: minio}]
${TARGET}"
}
case_18() {
  minio_patch "patch: |-
  - op: replace
    path: /spec/template/spec/enableServiceLinks
    value: false
${TARGET}"
}
case_19() {
  profile_patch minio "- ${TARGET}
  patch: |-
$(indent 4 "$(smp TRUE)")"
}
case_20() {
  profile_patch minio "- ${TARGET}
  patch: |-
    - op: remove
      path: /spec/template/spec/enableServiceLinks"
}
case_21() {
  profile_patch minio "- ${TARGET}
  patch: |-
$(indent 4 "$(smp false)")"
}
case_22() {
  mkdir -p "${R}/flux/infrastructure/newapp"
  smp TRUE | sed 's/name: minio$/name: newapp/' >"${R}/flux/infrastructure/newapp/deployment.yaml"
  write_file flux/bootstrap/profiles/local/newapp.yaml 'apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: newapp
  namespace: flux-system
spec:
  interval: 10m
  path: ./flux/infrastructure/newapp
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system'
  yq -i '.resources += ["newapp.yaml"]' "${R}/${PROFILE}"
}
case_23() {
  write_file "${MINIO}/broken.yaml" 'kind: Deployment
  bad: ['
  minio_patch 'path: broken.yaml'
}

case_24() {
  profile_patch apps-develop "- target: {kind: Kustomization, name: backend-develop}
  patch: |-
    - op: add
      path: /spec/patches
      value:
        - target: {kind: Deployment, name: backend}
          patch: |-
            - op: replace
              path: /spec/template/spec/enableServiceLinks
              value: true"
}

case_25() {
  drop_field flux/infrastructure/progressive-delivery/develop/synthetic-traffic.yaml
}
case_26() {
  write_file flux/bootstrap/profiles/local/foreign.yaml 'apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: foreign
  namespace: flux-system
spec:
  interval: 10m
  path: ./deploy
  prune: true
  sourceRef:
    kind: GitRepository
    name: someone-else'
  yq -i '.resources += ["foreign.yaml"]' "${R}/${PROFILE}"
}
case_27() {
  write_file flux/bootstrap/profiles/local/old.yaml 'apiVersion: kustomize.toolkit.fluxcd.io/v1beta2
kind: Kustomization
metadata:
  name: old
  namespace: flux-system
spec:
  interval: 10m
  path: ./flux/infrastructure/data/minio
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system'
  yq -i '.resources += ["old.yaml"]' "${R}/${PROFILE}"
}
# A file no build deploys, with the kind and name of a built workload (Deployment minio) in another namespace.
case_28() {
  write_file flux/infrastructure/data/minio-copy/deployment.yaml 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: other
spec:
  selector:
    matchLabels: {app: minio}
  template:
    metadata:
      labels: {app: minio}
    spec:
      enableServiceLinks: true
      containers:
        - name: minio
          image: minio'
}
# An opt-in copy of a deployed workload - same kind, namespace and name as the built Deployment minio -
# that no build reaches, without the field: the safe build of the real one does not cover it.
case_29() {
  yq 'del(.spec.template.spec.enableServiceLinks)' "${R}/${MINIO}/deployment.yaml" >"${R}/${MINIO}-opt-in.yaml"
}
# An opt-in overlay no profile deploys, with a patch that sets the field TRUE: no Flux build reaches it and
# the file check skips patches/, so only rendering the directory on its own sees it.
case_30() {
  write_file flux/infrastructure/data/minio-opt-in/kustomization.yaml 'apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../minio
patches:
  - path: patches/links.yaml'
  write_file flux/infrastructure/data/minio-opt-in/patches/links.yaml "$(smp TRUE)"
}

# The IPv4/IPv6 twin rule on NetworkPolicy ipBlocks (allow-backend-egress-https: both families, IPv6 excepts).
NP="flux/infrastructure/network-policies/base"
case_31() {
  yq -i 'del(.spec.egress[0].to[] | select(.ipBlock.cidr == "::/0"))' "${R}/${NP}/allow-postgres-egress-https.yaml"
}
case_32() {
  yq -i 'del(.spec.egress[0].to[] | select(.ipBlock.cidr == "0.0.0.0/0"))' "${R}/${NP}/allow-postgres-egress-https.yaml"
}
case_34() {
  yq -i '(.spec.egress[0].to[] | select(.ipBlock.cidr == "::/0") | .ipBlock.except) |= map(select(. != "64:ff9b::/96"))' \
    "${R}/${NP}/allow-backend-egress-https.yaml"
}
# A policy with two egress rules and one ingress rule: the ingress rule is named ingress[0], not ingress[2].
case_35() {
  write_file "${NP}/ingress-test.yaml" 'apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ingress-test
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  egress:
    - to: [{podSelector: {}}]
    - to: [{namespaceSelector: {}}]
  ingress:
    - from: [{ipBlock: {cidr: 0.0.0.0/0}}]'
}
# An unrestricted ::/0 first, the restricted one after it: the check must not read only the last block.
case_36() {
  yq -i '.spec.egress[0].to = [{"ipBlock": {"cidr": "::/0"}}] + .spec.egress[0].to' "${R}/${NP}/allow-backend-egress-https.yaml"
}
case_33() {
  yq -i '(.spec.egress[0].to[] | select(.ipBlock.cidr == "::/0") | .ipBlock.except) |= map(select(. != "fe80::/10"))' \
    "${R}/${NP}/allow-backend-egress-https.yaml"
}

# CASES - function|expected verdict|reason a fail must name (empty: the rule itself)|name. A case that edits a
# workload file names the build's own line (kind namespace/name), which the file check never prints - so
# it proves the build check, not only the check of the file as written ("): " ends the build's prefix;
# a directory's kustomize render prints "kustomize DIR: " instead).
CASES=(
  'case_01|pass||the repository as it is passes'
  'case_02|fail|): Deployment minio/minio has enableServiceLinks|a platform Deployment without the field fails'
  'case_03|fail|): CronJob flux-system/chaos-monkey has enableServiceLinks|a CronJob without the field (pod spec one level deeper) fails'
  'case_04|fail|): Deployment develop/backend has enableServiceLinks|an app base Deployment without the field fails'
  'case_05|pass||a patch that leaves the field out passes'
  'case_06|fail||a patch file with true fails'
  'case_07|fail||a patch file with TRUE fails (YAML reads it as the boolean true)'
  'case_08|fail||a patch file with True fails'
  'case_09|fail||a patch file with yes fails (the API server reads it as true)'
  'case_10|fail||a patch file with the quoted string false fails (only the boolean false)'
  'case_11|pass||a patch file that repeats the boolean false passes'
  'case_12|fail||a $patch: replace of the pod spec (the field gone) fails'
  'case_13|fail||an inline patch with two documents, the second one TRUE, fails'
  'case_14|fail||a JSON patch that removes it fails (an absent field defaults to true)'
  'case_15|fail||a JSON patch that moves it away fails'
  'case_16|fail||a JSON patch file that sets it true fails'
  'case_17|fail||a JSON patch that replaces the whole pod spec fails'
  'case_18|pass||a JSON patch that keeps it false passes'
  'case_19|fail||a profile'"'"'s patch on a Flux Kustomization with TRUE fails'
  'case_20|fail||a profile'"'"'s JSON patch on a Flux Kustomization that removes it fails'
  'case_21|pass||a profile'"'"'s patch on a Flux Kustomization that keeps it false passes'
  'case_22|fail|): Deployment minio/newapp has enableServiceLinks|a workload in a path without kustomization.yaml (Flux generates one) is checked'
  'case_23|fail|build failed|a kustomization that does not build fails the check'
  'case_24|fail||a patch two Flux Kustomizations deep (profile -> apps-develop -> backend-develop) fails'
  'case_25|fail|checked in the file|a workload file no profile deploys (the opt-in canary) is checked in the file'
  'case_26|fail|add it to FOREIGN_SOURCES|a Flux Kustomization on an unknown other source fails'
  'case_27|fail|builds kustomize.toolkit.fluxcd.io/v1 only|a Flux Kustomization with another apiVersion fails'
  'case_28|fail|checked in the file|a file no build deploys, named like a built workload in another namespace, is checked in the file'
  'case_29|fail|checked in the file|an unbuilt copy of a deployed workload (same kind, namespace and name) is checked in the file'
  'case_30|fail|kustomize flux/infrastructure/data/minio-opt-in|a patch in an overlay no profile deploys is rendered and checked'
  'case_31|fail|add the IPv6 twin|a NetworkPolicy rule with 0.0.0.0/0 and no ::/0 fails'
  'case_32|fail|one rule for both families|a NetworkPolicy rule with ::/0 and no 0.0.0.0/0 fails'
  'case_33|fail|does not cut out fe80::/10|IPv4 private ranges cut out but IPv6 link-local left open fails'
  'case_34|fail|does not cut out 64:ff9b::/96|IPv4 private ranges cut out but the NAT64 prefix left open fails'
  'case_35|fail|ingress[0] opens 0.0.0.0/0 but not ::/0|an ingress rule is checked and named by its own index'
  'case_36|fail|a ::/0 block does not cut out fc00::/7|an unrestricted ::/0 listed before the restricted one is still caught'
)

# run_case FUNCTION EXPECTED REASON NAME - set up the case's copy, run the check, write "ok   - NAME" or
# "FAIL - ..." to its result file.
run_case() {
  local fn="$1" expected="$2" reason="${3:-${RULE}}" name="$4" out got
  R="${WORK}/${fn}"
  fresh_copy
  "${fn}"
  if out="$("${R}/scripts/check-app-security.sh" 2>&1)"; then got=pass; else got=fail; fi
  if [[ "${got}" == fail ]] && { ! grep -qF -- "${reason}" <<<"${out}" ||
    { [[ "${reason}" == "${RULE}" ]] && grep -qF 'build failed' <<<"${out}"; }; }; then
    got="fail for another reason: $(grep -m1 -e '  - ' <<<"${out}" || tail -1 <<<"${out}")"
  fi
  if [[ "${got}" == "${expected}" ]]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}: expected ${expected}, got ${got}"
  fi >"${WORK}/${fn}.result"
}

# At most one case per CPU at a time: each one runs ~66 flux builds.
max_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
for row in "${CASES[@]}"; do
  IFS='|' read -r fn expected reason name <<<"${row}"
  while (($(jobs -rp | wc -l) >= max_jobs)); do sleep 0.2; done
  run_case "${fn}" "${expected}" "${reason}" "${name}" &
done
wait
FAILED=0
for row in "${CASES[@]}"; do
  fn="${row%%|*}"
  if [[ -f "${WORK}/${fn}.result" ]]; then cat "${WORK}/${fn}.result"; else echo "FAIL - ${fn}: no result"; fi
  grep -q '^ok ' "${WORK}/${fn}.result" 2>/dev/null || FAILED=1
done
exit "${FAILED}"
