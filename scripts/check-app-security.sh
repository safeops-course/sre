#!/usr/bin/env bash
# Guardrail for the app manifests (security review 2026-09-27). Renders every backend and frontend
# overlay and fails when a rule is broken:
#   - every Deployment: automountServiceAccountToken: false (the apps never call the Kubernetes API)
#     and enableServiceLinks: false
#   - every workload written under flux/ (Deployment, StatefulSet, DaemonSet, Job, CronJob; overlay
#     patches aside - the rendered overlays above cover them): enableServiceLinks: false. Kubernetes
#     otherwise adds variables for every Service in the namespace - BACKEND_PORT=tcp://<ip>:80, ... -
#     and one collided with a frontend setting and crash-looped it (frontend#25). Only the environment
#     written in the manifest; names resolve through DNS (KUBERNETES_SERVICE_HOST is added either way)
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
# Runs in pre-commit (flux/**) and in the Flux Diff workflow. Needs kubectl (for `kubectl kustomize`) and yq (v4).
# Usage: scripts/check-app-security.sh   (no arguments - it always checks all six overlays)
# Read-only: it renders the overlays locally and changes no file and no cluster. Every problem is
# collected first and printed together; exit 1 when there is at least one.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

for tool in kubectl yq; do
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

  # Rule: automountServiceAccountToken and enableServiceLinks false on every Deployment - and count
  # the Deployments, so an overlay that renders none fails instead of passing with nothing checked.
  deployments=0
  while IFS=$'\t' read -r name automount links; do
    [[ -z "${name}" ]] && continue
    deployments=$((deployments + 1))
    if [[ "${automount}" != "false" ]]; then
      failures+=("${overlay}: Deployment ${name} must set automountServiceAccountToken: false (got: ${automount})")
    fi
    if [[ "${links}" != "false" ]]; then
      failures+=("${overlay}: Deployment ${name} must set enableServiceLinks: false (got: ${links})")
    fi
  done < <(yq 'select(.kind == "Deployment") | [.metadata.name, (.spec.template.spec.automountServiceAccountToken | tostring),
      (.spec.template.spec.enableServiceLinks | tostring)] | @tsv' <<<"${rendered}")
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

# Rule: enableServiceLinks: false on every workload written under flux/, not only the apps. Overlay
# patches are partial objects (the rendered overlays above are checked whole); a top-level list (a JSON
# patch) is no workload. A CronJob's pod spec sits one level deeper.
# Read into a variable first: a file yq cannot parse must fail the check, not end the list early.
workloads=0
if ! workload_list="$(find flux -type f \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/patches/*' -print0 | sort -z |
  xargs -0 yq -N 'select(tag == "!!map")
    | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob")
    | [filename, .kind, .metadata.name, ((.spec.jobTemplate.spec.template.spec // .spec.template.spec).enableServiceLinks | tostring)]
    | @tsv' 2>&1)"; then
  failures+=("flux/: yq could not read the workloads: ${workload_list}")
  workload_list=""
fi
while IFS=$'\t' read -r file kind name links; do
  [[ -z "${file}" ]] && continue
  workloads=$((workloads + 1))
  if [[ "${links}" != "false" ]]; then
    failures+=("${file}: ${kind} ${name} must set enableServiceLinks: false in its pod spec (got: ${links})")
  fi
done <<<"${workload_list}"
if ((workloads == 0)); then
  failures+=("flux/: no workload found - nothing was checked for enableServiceLinks")
fi

if ((${#failures[@]} > 0)); then
  echo "check-app-security: ${#failures[@]} problem(s):" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi
echo "check-app-security: OK (${#overlays[@]} overlays, ${workloads} workloads under flux/)"
