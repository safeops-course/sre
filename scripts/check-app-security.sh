#!/usr/bin/env bash
# Guardrail for the app manifests (security review 2026-09-27) - and, for service links, for every
# workload written under flux/, the platform's own too. Renders every backend and frontend overlay and
# fails when a rule is broken:
#   - every Deployment: automountServiceAccountToken: false (the apps never call the Kubernetes API)
#   - every workload Flux deploys from flux/ (Deployment, StatefulSet, DaemonSet, Job, CronJob - apps
#     and platform; not the pods Helm charts and operators create) has enableServiceLinks: false - the
#     boolean - in the form Flux applies it: every Flux Kustomization is built with `flux build` (its
#     patches too), so no patch can take it away - and in every workload file as written, so a file
#     no build reaches (an opt-in manifest, an alternate copy of a deployed one) is checked too. Kubernetes otherwise
#     adds variables for every Service in the namespace - BACKEND_PORT=tcp://<ip>:80, ... - to every new
#     pod; BACKEND_PORT had the name of a frontend setting and would have crash-looped every new frontend
#     pod (frontend#25, caught on kind before it shipped). Without them no variable of the namespace's
#     Services reaches the pod; names resolve through DNS. KUBERNETES_SERVICE_HOST / _PORT (the API
#     server) are still added - the kubelet adds them either way
#   - every container (and init container): runAsNonRoot, readOnlyRootFilesystem, no privilege
#     escalation, capabilities drop ALL, seccomp RuntimeDefault - the container value wins over
#     the pod's, as in Kubernetes. Pod Security "restricted" (enforced on develop, staging and
#     production) also refuses a pod without the non-root, escalation, capabilities and seccomp
#     settings - but only when it is created, in the cluster. This check stops the same regression
#     in the pull request, and adds what Restricted does not require: readOnlyRootFilesystem.
#   - every emptyDir volume has a sizeLimit (an unlimited one can grow until the node's disk is full;
#     the kubelet evicts a pod over its limit when it next measures - a budget, not a quota)
#   - every app container waits before it stops: lifecycle.preStop.sleep of at least MIN_PRESTOP
#     seconds, and a grace period that still leaves MIN_SHUTDOWN seconds after the sleep - the
#     grace countdown starts with the preStop hook, so the app's own shutdown comes out of it too.
#     A stopping pod is removed from the Service's endpoints and from Traefik while it already
#     shuts down; without the wait it refuses requests still sent to it. Measured on kind (Chapter 20): the wait removed the frontend's failures and
#     the backend's refused connections; a few backend timeouts remained, with 5 s and with 10 s
#   - backend: PPROF_ENABLED is "false" everywhere (profiling is turned on by hand, never in Git)
#   - backend: CHAOS_ENABLED is exactly "true" in develop and staging (the chaos labs need it) and
#     "false" in production
#   - production: no container sets RANDOM_ERROR_RATE (fault injection - backend Ch15, frontend Ch19)
#   - every overlay renders at least one Deployment (an empty render must not pass as OK)
#   - a Deployment targeted by an HPA sets no spec.replicas (the HPA owns the count; a value in Git
#     makes Flux reset what the HPA scaled on every reconcile)
#
# Runs in pre-commit (flux/**) and in the Flux Diff workflow. Needs kubectl (for `kubectl kustomize`), yq (v4)
# and the flux CLI (`flux build`, no cluster).
# Usage: scripts/check-app-security.sh   (no arguments - it always checks all six overlays)
# Read-only: it renders the overlays locally and changes no file and no cluster. Every problem is
# collected first and printed together; exit 1 when there is at least one.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

for tool in kubectl yq flux; do
  command -v "${tool}" >/dev/null || { echo "check-app-security: ${tool} is required" >&2; exit 1; }
done

# The overlays Flux deploys: one per app and environment.
overlays=(
  flux/apps/backend/develop
  flux/apps/backend/staging
  flux/apps/backend/production
  flux/apps/frontend/overlays/develop
  flux/apps/frontend/overlays/staging
  flux/apps/frontend/overlays/production
)

failures=()
MIN_PRESTOP=5   # seconds; on kind 10 s did no better than 5 s
MIN_SHUTDOWN=10 # seconds the app needs after the sleep: the backend's graceful shutdown timeout (cmd/api/main.go)

# The only accepted CHAOS_ENABLED per backend overlay (a case, not an associative array: macOS /bin/bash is 3.2).
expected_chaos_for() {
  case "$1" in
    flux/apps/backend/develop | flux/apps/backend/staging) echo true ;;
    flux/apps/backend/production) echo false ;;
    *) echo "" ;;
  esac
}

# backend_env OVERLAY_YAML NAME -> the value of env NAME in the backend container ("" when unset)
backend_env() {
  yq "select(.kind == \"Deployment\" and .metadata.name == \"backend\")
      | .spec.template.spec.containers[] | select(.name == \"backend\")
      | .env[] | select(.name == \"$2\") | .value" <<<"$1"
}

for overlay in "${overlays[@]}"; do
  # Render the overlay exactly as Flux would build it; every rule below reads this output.
  if ! rendered="$(kubectl kustomize "${overlay}" 2>&1)"; then
    failures+=("${overlay}: kustomize build failed: ${rendered}")
    continue
  fi

  # Rule: automountServiceAccountToken: false on every Deployment - and count the Deployments,
  # so an overlay that renders none fails instead of passing with nothing checked.
  deployments=0
  while IFS=$'\t' read -r name automount; do
    [[ -z "${name}" ]] && continue
    deployments=$((deployments + 1))
    if [[ "${automount}" != "false" ]]; then
      failures+=("${overlay}: Deployment ${name} must set automountServiceAccountToken: false (got: ${automount})")
    fi
  done < <(yq 'select(.kind == "Deployment") | [.metadata.name, (.spec.template.spec.automountServiceAccountToken | tostring)] | @tsv' <<<"${rendered}")
  if ((deployments == 0)); then
    failures+=("${overlay}: renders no Deployment - nothing was checked")
  fi

  # One line per container: deployment, container, runAsNonRoot (container, pod), readOnlyRootFilesystem,
  # allowPrivilegeEscalation, capabilities.drop, seccomp type (container, pod). Both levels are printed
  # and decided here: yq's // would treat an explicit false on the container as unset.
  # shellcheck disable=SC2016 # $pod and $d below are yq variables, not shell ones
  while IFS=$'\t' read -r dep ctr nonroot_c nonroot_p rofs ape drop seccomp_c seccomp_p; do
    [[ -z "${ctr}" ]] && continue
    where="${overlay}: Deployment ${dep} container ${ctr}"
    nonroot="${nonroot_c}"; [[ "${nonroot}" == "null" ]] && nonroot="${nonroot_p}"
    seccomp="${seccomp_c}"; [[ "${seccomp}" == "null" ]] && seccomp="${seccomp_p}"
    [[ "${nonroot}" == "true" ]] || failures+=("${where}: runAsNonRoot must be true (got: ${nonroot})")
    [[ "${rofs}" == "true" ]] || failures+=("${where}: readOnlyRootFilesystem must be true (got: ${rofs})")
    [[ "${ape}" == "false" ]] || failures+=("${where}: allowPrivilegeEscalation must be false (got: ${ape})")
    [[ ",${drop}," == *",ALL,"* ]] || failures+=("${where}: capabilities.drop must include ALL (got: '${drop}')")
    [[ "${seccomp}" == "RuntimeDefault" || "${seccomp}" == "Localhost" ]] ||
      failures+=("${where}: seccompProfile must be RuntimeDefault (got: ${seccomp})")
  done < <(yq 'select(.kind == "Deployment") | .spec.template.spec as $pod | .metadata.name as $d
      | ($pod.containers + ($pod.initContainers // []))[]
      | [$d, .name,
         (.securityContext.runAsNonRoot | tostring), ($pod.securityContext.runAsNonRoot | tostring),
         (.securityContext.readOnlyRootFilesystem | tostring),
         (.securityContext.allowPrivilegeEscalation | tostring),
         ((.securityContext.capabilities.drop // []) | join(",")),
         (.securityContext.seccompProfile.type | tostring), ($pod.securityContext.seccompProfile.type | tostring)]
      | @tsv' <<<"${rendered}")

  # Rule: every app container sleeps MIN_PRESTOP seconds or more before it is stopped, and the
  # grace period (default 30 s) leaves room for that sleep plus the app's own shutdown.
  while IFS=$'\t' read -r dep container sleep grace; do
    [[ -n "${dep}" && "${dep}" != "---" ]] || continue   # yq separates the documents with ---
    where="${overlay}: Deployment ${dep} container ${container}"
    if [[ ! "${grace}" =~ ^[0-9]+$ ]]; then
      failures+=("${where}: terminationGracePeriodSeconds must be a whole number of seconds (got: ${grace})")
      continue
    fi
    if [[ ! "${sleep}" =~ ^[0-9]+$ ]] || ((sleep < MIN_PRESTOP)); then
      failures+=("${where}: lifecycle.preStop.sleep.seconds must be at least ${MIN_PRESTOP} (got: ${sleep})")
    elif ((grace < sleep + MIN_SHUTDOWN)); then
      failures+=("${where}: terminationGracePeriodSeconds (${grace}s) must cover the preStop sleep (${sleep}s) plus ${MIN_SHUTDOWN}s of shutdown")
    fi
  done < <(yq 'select(.kind == "Deployment") | .metadata.name as $d
      | (.spec.template.spec.terminationGracePeriodSeconds // 30) as $g
      | .spec.template.spec.containers[]
      | [$d, .name, (.lifecycle.preStop.sleep.seconds // "none" | tostring), ($g | tostring)] | @tsv' <<<"${rendered}")

  # Rule: every emptyDir has a sizeLimit - a writable path is the price of a read-only root
  # filesystem, and it must not be able to fill the node's disk.
  # shellcheck disable=SC2016 # $d below is a yq variable, not a shell one
  while IFS=$'\t' read -r dep vol limit; do
    [[ -z "${vol}" ]] && continue
    if [[ "${limit}" == "null" || -z "${limit}" ]]; then
      failures+=("${overlay}: Deployment ${dep} emptyDir volume ${vol} must set a sizeLimit")
    fi
  done < <(yq 'select(.kind == "Deployment") | .metadata.name as $d
      | (.spec.template.spec.volumes // [])[] | select(has("emptyDir"))
      | [$d, .name, (.emptyDir.sizeLimit | tostring)] | @tsv' <<<"${rendered}")

  # Rule: for every Deployment an HPA scales, no spec.replicas in Git.
  while IFS= read -r target; do
    [[ -z "${target}" ]] && continue
    replicas="$(yq "select(.kind == \"Deployment\" and .metadata.name == \"${target}\") | .spec.replicas" <<<"${rendered}")"
    if [[ -n "${replicas}" && "${replicas}" != "null" ]]; then
      failures+=("${overlay}: Deployment ${target} has an HPA and must not set spec.replicas (got: ${replicas})")
    fi
  done < <(yq 'select(.kind == "HorizontalPodAutoscaler" and .spec.scaleTargetRef.kind == "Deployment") | .spec.scaleTargetRef.name' <<<"${rendered}")

  # Rule: no injected errors in production, in any container of either app.
  if [[ "${overlay}" == */production ]]; then
    # shellcheck disable=SC2016 # $d below is a yq variable, not a shell one
    while IFS=$'\t' read -r dep container; do
      [[ -z "${dep}" ]] && continue
      failures+=("${overlay}: Deployment ${dep} container ${container} must not set RANDOM_ERROR_RATE in production")
    done < <(yq -N 'select(.kind == "Deployment") | .metadata.name as $d
        | ((.spec.template.spec.containers // []) + (.spec.template.spec.initContainers // []))[]
        | select((.env // [])[] | .name == "RANDOM_ERROR_RATE")
        | [$d, .name] | @tsv' <<<"${rendered}")
  fi

  # Rules for the backend only: PPROF_ENABLED off, CHAOS_ENABLED as expected for the environment.
  if [[ "${overlay}" == flux/apps/backend/* ]]; then
    pprof="$(backend_env "${rendered}" PPROF_ENABLED)"
    chaos="$(backend_env "${rendered}" CHAOS_ENABLED)"
    if [[ "${pprof}" != "false" ]]; then
      failures+=("${overlay}: backend PPROF_ENABLED must be \"false\" in Git (got: '${pprof}')")
    fi
    expected="$(expected_chaos_for "${overlay}")"
    if [[ -z "${expected}" ]]; then
      failures+=("${overlay}: no expected CHAOS_ENABLED value - add the overlay to expected_chaos_for")
    elif [[ "${chaos}" != "${expected}" ]]; then
      failures+=("${overlay}: backend CHAOS_ENABLED must be \"${expected}\" (got: '${chaos}')")
    fi
  fi
done

# Rule: enableServiceLinks: false on every workload under flux/ - checked on what Flux would apply, not
# on the source text, so no form of patch can take it away (a `TRUE` or `yes` that the API server reads
# as true, a `remove`, `$patch: replace`, a patch a profile adds to a Flux Kustomization).
# `flux build kustomization --dry-run` (no cluster) builds each Flux Kustomization the way the
# kustomize-controller does: its path - with a generated kustomization.yaml when there is none - its
# spec.patches and its postBuild substitutions. It starts from the Flux Kustomizations in each profile
# (flux/bootstrap/profiles/*) and follows every Flux Kustomization those builds contain, until none is
# new. In every build each Deployment, StatefulSet, DaemonSet, Job and CronJob must have the boolean
# false in its pod spec; a workload (kind, namespace/name) is reported once per build check.
#   - A Flux Kustomization on another source than this repository cannot be built here. Each one must be
#     in FOREIGN_SOURCES, checked by hand to deploy no workload of ours; any other fails the check.
#   - Every kustomize directory under flux/ (kustomization.yaml, not a Component) is also rendered on its
#     own with `kubectl kustomize`, so a patch in an overlay no profile reaches yet is checked too.
#   - Every workload document under flux/ is also checked as written, built or not: the field must be
#     there, as the boolean false - "every workload you write sets it" (Ch07 agent rule 5). That covers
#     a file no build reaches (the develop canary, an opt-in copy of a deployed workload); a matching
#     build is no proof the build used that file. So the field is written in the workload itself, never
#     only by an overlay patch or a postBuild variable, and a partial workload (a patch) lives in a
#     patches/ directory. A missing field in a built workload is reported twice: by its build and its file.
FOREIGN_SOURCES=(origin-ca-issuer-crds)   # origin-ca-issuer's CRDs (deploy/crds): no workload
render_tmp="$(mktemp -d)"
trap 'rm -rf "${render_tmp}"' EXIT
links_rows="${render_tmp}/rows.tsv"   # kind, namespace/name, YAML tag + value, build - per workload per build
queue="${render_tmp}/queue"           # the split Flux Kustomizations; pending lists the ones still to build
mkdir -p "${queue}"
: >"${links_rows}" && : >"${render_tmp}/seen"
pending=()
enqueued=0

# enqueue YAML_FILE WHERE - add every Flux Kustomization in YAML_FILE (built by WHERE) that is new to
# pending. New means a new combination of what shapes its build: name, namespace, source, path,
# patches, components, target namespace, postBuild - the same one comes from several profiles.
enqueue() {
  local file api key
  enqueued=$((enqueued + 1))
  yq 'select(.kind == "Kustomization" and ((.apiVersion // "") | test("^kustomize\.toolkit\.fluxcd\.io/")))' \
    "$1" >"${render_tmp}/ks.yaml"
  [[ -s "${render_tmp}/ks.yaml" ]] || return 0
  # yq -s writes one file per document; the `---` the yq above prints between documents keeps them apart.
  (cd "${queue}" && yq -s '"ks-'"${enqueued}"'-" + $index' "${render_tmp}/ks.yaml")
  for file in "${queue}/ks-${enqueued}-"*.yml; do
    if ! IFS=$'\t' read -r api key < <(yq -N '[.apiVersion, ([.metadata.name, .metadata.namespace,
        .spec.sourceRef, .spec.path, .spec.patches, .spec.components, .spec.targetNamespace,
        .spec.postBuild] | @json)] | @tsv' "${file}"); then
      failures+=("$2: a Flux Kustomization yq cannot read")
      continue
    fi
    if [[ "${api}" != "kustomize.toolkit.fluxcd.io/v1" ]]; then
      failures+=("$2: a Flux Kustomization with apiVersion ${api} - the check builds kustomize.toolkit.fluxcd.io/v1 only")
      continue
    fi
    key="$(cksum <<<"${key}")"
    grep -qxF "${key}" "${render_tmp}/seen" && continue
    echo "${key}" >>"${render_tmp}/seen"
    pending+=("${file}")
  done
}

# The yq that picks the workloads out of a YAML stream and binds $p to their pod spec's field - shared by
# the build check and the file check, so both cover the same kinds.
# shellcheck disable=SC2016 # $p is a yq variable, not a shell one
WORKLOAD_LINKS='select(tag == "!!map")
  | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob")
  | (.spec.jobTemplate.spec.template.spec // .spec.template.spec).enableServiceLinks as $p'

# collect_links BUILD BUILT_FILE - a row per workload in BUILT_FILE: kind, namespace/name, the field's YAML
# tag and value ("!!null null" when it is missing), BUILD.
collect_links() {
  BUILD="$1" yq -N "${WORKLOAD_LINKS}"' | [.kind, (.metadata.namespace // "-") + "/" + .metadata.name, (($p | tag) + " " + ($p | tostring)), env(BUILD)]
      | @tsv' "$2" >>"${links_rows}"
}

for profile in flux/bootstrap/profiles/*/; do
  if ! kubectl kustomize --load-restrictor=LoadRestrictionsNone "${profile}" >"${render_tmp}/profile.yaml" 2>"${render_tmp}/err"; then
    failures+=("${profile}: kustomize build failed: $(cat "${render_tmp}/err")")
    continue
  fi
  enqueue "${render_tmp}/profile.yaml" "${profile}"
done
builds=0
next=0
while ((next < ${#pending[@]})); do
  file="${pending[next]}"
  next=$((next + 1))
  # Name, path (Flux's default: the source root) and source as kind/namespace/name - the source's
  # namespace defaults to the Kustomization's own.
  if ! IFS=$'\t' read -r name source path < <(yq -N '[.metadata.name,
      .spec.sourceRef.kind + "/" + (.spec.sourceRef.namespace // .metadata.namespace // "flux-system") + "/" + .spec.sourceRef.name,
      .spec.path // "./"] | @tsv' "${file}"); then
    failures+=("${file##*/}: a Flux Kustomization yq cannot read")
    continue
  fi
  if [[ "${source}" != "GitRepository/flux-system/flux-system" ]]; then
    if [[ " ${FOREIGN_SOURCES[*]} " != *" ${name} "* ]]; then
      failures+=("Flux Kustomization ${name}: its source ${source} is not this repository, so it cannot be built here - if it deploys no workload of ours, add it to FOREIGN_SOURCES")
    fi
    continue
  fi
  builds=$((builds + 1))
  if ! flux build kustomization "${name}" --path "${path}" --kustomization-file "${file}" \
    --dry-run >"${render_tmp}/built.yaml" 2>"${render_tmp}/err"; then
    failures+=("Flux Kustomization ${name} (${path}): flux build failed: $(cat "${render_tmp}/err")")
    continue
  fi
  collect_links "Flux Kustomization ${name} (${path})" "${render_tmp}/built.yaml"
  enqueue "${render_tmp}/built.yaml" "Flux Kustomization ${name} (${path})"
done

workloads="$(cut -f1,2 "${links_rows}" | sort -u | grep -c . || true)"

# Every kustomize directory under flux/ rendered on its own too, reached by a profile or not: a patch in an
# opt-in overlay no profile deploys yet is rendered and checked here (the file check skips patches/).
# Components are no build of their own - their patches are rendered where an overlay uses them.
dirs=0
while IFS= read -r -d '' kfile; do
  [[ "$(yq '.kind // "Kustomization"' "${kfile}")" == Component ]] && continue
  dirs=$((dirs + 1))
  if ! kubectl kustomize --load-restrictor=LoadRestrictionsNone "$(dirname "${kfile}")" \
    >"${render_tmp}/dir.yaml" 2>"${render_tmp}/err"; then
    failures+=("$(dirname "${kfile}"): kustomize build failed: $(cat "${render_tmp}/err")")
    continue
  fi
  collect_links "kustomize $(dirname "${kfile}")" "${render_tmp}/dir.yaml"
done < <(find flux -name kustomization.yaml -print0 | sort -z)

# One line per workload (kind, namespace/name): the first build that shows a wrong value is enough to find it.
while IFS=$'\t' read -r kind name value build; do
  [[ -z "${kind}" ]] && continue
  failures+=("${build}: ${kind} ${name} has enableServiceLinks ${value#* } (${value%% *}) - it must be the boolean false")
done < <(awk -F'\t' '$3 != "!!bool false" && !seen[$1 FS $2]++' "${links_rows}")
if ((workloads == 0)); then
  failures+=("flux/: no workload built - nothing was checked for enableServiceLinks")
fi

# Every workload document, checked as written - whether a build reached it or not (see the rule above).
# Overlay patches are partial objects, not workloads.
documents=0
# shellcheck disable=SC2016 # $p is a yq variable, not a shell one
if ! sources="$(find flux -type f \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/patches/*' -print0 | sort -z |
  xargs -0 yq -N "${WORKLOAD_LINKS}"' | [.kind, .metadata.name, (($p | tag) + " " + ($p | tostring)), filename] | @tsv' 2>"${render_tmp}/err")"; then
  failures+=("flux/: yq could not read the workload files: $(cat "${render_tmp}/err")")
  sources=""
fi
while IFS=$'\t' read -r kind name value file; do
  [[ -z "${kind}" ]] && continue
  documents=$((documents + 1))
  if [[ "${value}" != "!!bool false" ]]; then
    failures+=("${file}: ${kind} ${name} (checked in the file) has enableServiceLinks ${value#* } (${value%% *}) - it must be the boolean false")
  fi
done <<<"${sources}"

if ((${#failures[@]} > 0)); then
  echo "check-app-security: ${#failures[@]} problem(s):" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi
echo "check-app-security: OK (${#overlays[@]} overlays; ${builds} Flux Kustomizations built, ${workloads} workloads; ${dirs} kustomize directories rendered; ${documents} workload documents checked as written)"
