#!/usr/bin/env bash
set -euo pipefail

# Flux manifest validation modeled after the official Flux example:
# YAML syntax (yq) + kustomize build + kubeconform + Flux CRD schemas.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUX_ROOT="${REPO_ROOT}/flux"

SCHEMA_URL="${FLUX_VALIDATE_SCHEMA_URL:-https://github.com/fluxcd/flux2/releases/latest/download/crd-schemas.tar.gz}"
SCHEMA_ROOT="${FLUX_VALIDATE_SCHEMA_ROOT:-/tmp/flux-crd-schemas}"
SCHEMA_VARIANT="${FLUX_VALIDATE_SCHEMA_VARIANT:-master-standalone-strict}"
SCHEMA_DIR="${SCHEMA_ROOT}/${SCHEMA_VARIANT}"
ALLOW_NO_FLUX_SCHEMAS="${FLUX_VALIDATE_ALLOW_NO_FLUX_SCHEMAS:-0}"
DISABLE_SCHEMA_DOWNLOAD="${FLUX_VALIDATE_DISABLE_SCHEMA_DOWNLOAD:-0}"

kustomize_flags=(--load-restrictor=LoadRestrictionsNone)
kubeconform_flags=(-skip=Secret)

for tool in yq kustomize kubeconform tar; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "[flux-validate] required tool missing: ${tool}" >&2
    exit 1
  fi
done

if [[ "${DISABLE_SCHEMA_DOWNLOAD}" != "1" ]] && ! command -v curl >/dev/null 2>&1; then
  echo "[flux-validate] required tool missing: curl" >&2
  exit 1
fi

if [[ ! -d "${FLUX_ROOT}" ]]; then
  echo "[flux-validate] flux/ directory not found at ${FLUX_ROOT}" >&2
  exit 1
fi

contains_kustomization() {
  local dir="$1"
  [[ -f "${dir}/kustomization.yaml" || -f "${dir}/kustomization.yml" ]]
}

has_local_flux_schemas() {
  [[ -d "${SCHEMA_DIR}" ]] && find "${SCHEMA_DIR}" -type f -name '*.json' -print -quit | grep -q .
}

download_flux_schemas() {
  local tmp_archive
  tmp_archive="$(mktemp "/tmp/flux-crd-schemas.XXXXXX.tar.gz")"

  echo "[flux-validate] downloading Flux CRD schemas from ${SCHEMA_URL}"
  if ! curl -fsSL "${SCHEMA_URL}" -o "${tmp_archive}"; then
    rm -f "${tmp_archive}"
    return 1
  fi

  rm -rf "${SCHEMA_DIR}"
  mkdir -p "${SCHEMA_DIR}"
  if ! tar zxf "${tmp_archive}" -C "${SCHEMA_DIR}"; then
    rm -f "${tmp_archive}"
    return 1
  fi

  rm -f "${tmp_archive}"
}

ensure_flux_schemas() {
  if has_local_flux_schemas; then
    echo "[flux-validate] using cached Flux schemas at ${SCHEMA_DIR}"
    return 0
  fi

  if [[ "${DISABLE_SCHEMA_DOWNLOAD}" == "1" ]]; then
    if [[ "${ALLOW_NO_FLUX_SCHEMAS}" == "1" ]]; then
      echo "[flux-validate] WARNING: Flux schema download disabled, validating without Flux CRD schemas."
      return 0
    fi
    echo "[flux-validate] Flux schemas missing and download disabled." >&2
    echo "[flux-validate] Set FLUX_VALIDATE_ALLOW_NO_FLUX_SCHEMAS=1 to allow fallback." >&2
    return 1
  fi

  if download_flux_schemas && has_local_flux_schemas; then
    echo "[flux-validate] Flux CRD schemas ready at ${SCHEMA_DIR}"
    return 0
  fi

  if [[ "${ALLOW_NO_FLUX_SCHEMAS}" == "1" ]]; then
    echo "[flux-validate] WARNING: failed to prepare Flux schemas, falling back without CRD schemas."
    return 0
  fi

  echo "[flux-validate] failed to prepare Flux schemas." >&2
  echo "[flux-validate] Set FLUX_VALIDATE_ALLOW_NO_FLUX_SCHEMAS=1 to allow fallback." >&2
  return 1
}

declare -A UNIQUE_DIRS=()
declare -A UNIQUE_YAML_FILES=()

add_kustomize_parents() {
  local path="$1"
  local abs_path

  if [[ "${path}" = /* ]]; then
    abs_path="${path}"
  else
    abs_path="${REPO_ROOT}/${path}"
  fi

  local dir="${abs_path}"
  if [[ ! -d "${dir}" ]]; then
    dir="$(dirname "${dir}")"
  fi

  while [[ "${dir}" == "${REPO_ROOT}"* && "${dir}" != "/" ]]; do
    if contains_kustomization "${dir}"; then
      UNIQUE_DIRS["${dir}"]=1
    fi
    if [[ "${dir}" == "${REPO_ROOT}" ]]; then
      break
    fi
    dir="$(dirname "${dir}")"
  done
}

if [[ $# -gt 0 ]]; then
  for changed in "$@"; do
    if [[ "${changed}" != flux/* ]]; then
      continue
    fi

    if [[ "${changed}" =~ \.ya?ml$ ]]; then
      if [[ -f "${REPO_ROOT}/${changed}" ]]; then
        UNIQUE_YAML_FILES["${REPO_ROOT}/${changed}"]=1
      fi
      add_kustomize_parents "${changed}"
    fi
  done
else
  while IFS= read -r -d '' yaml_file; do
    UNIQUE_YAML_FILES["${yaml_file}"]=1
  done < <(find "${FLUX_ROOT}" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

  while IFS= read -r -d '' kfile; do
    UNIQUE_DIRS["$(dirname "${kfile}")"]=1
  done < <(find "${FLUX_ROOT}" -type f \( -name 'kustomization.yaml' -o -name 'kustomization.yml' \) -print0)
fi

if [[ ${#UNIQUE_YAML_FILES[@]} -eq 0 && ${#UNIQUE_DIRS[@]} -eq 0 ]]; then
  echo "[flux-validate] No Flux manifests to validate."
  exit 0
fi

readarray -t YAML_FILES < <(printf '%s\n' "${!UNIQUE_YAML_FILES[@]}" | sort)
readarray -t TARGET_DIRS < <(printf '%s\n' "${!UNIQUE_DIRS[@]}" | sort)

echo "[flux-validate] validating YAML syntax with yq"
for yaml_file in "${YAML_FILES[@]}"; do
  rel_file="${yaml_file#${REPO_ROOT}/}"
  echo "[flux-validate] yq ${rel_file}"
  yq e 'true' "${yaml_file}" >/dev/null
done

if [[ ${#TARGET_DIRS[@]} -eq 0 ]]; then
  echo "[flux-validate] No kustomizations affected."
  exit 0
fi

ensure_flux_schemas

run_kubeconform=1
kubeconform_config=(-strict -ignore-missing-schemas -schema-location default)
if has_local_flux_schemas; then
  kubeconform_config+=(-schema-location "${SCHEMA_ROOT}")
elif [[ "${ALLOW_NO_FLUX_SCHEMAS}" == "1" ]]; then
  echo "[flux-validate] WARNING: skipping kubeconform (no local schemas available in fallback mode)."
  run_kubeconform=0
fi

failed=0
validated=0
skipped=0

for dir in "${TARGET_DIRS[@]}"; do
  rel_dir="${dir#${REPO_ROOT}/}"
  echo "[flux-validate] kustomize ${rel_dir}"

  set +e
  rendered="$(kustomize build "${dir}" "${kustomize_flags[@]}" 2>&1)"
  build_status=$?
  set -e

  if [[ ${build_status} -ne 0 ]]; then
    if grep -Eqi "must build at least one resource|kustomization\\.ya?ml is empty" <<<"${rendered}"; then
      echo "[flux-validate] skipped ${rel_dir} (empty kustomization)"
      skipped=$((skipped + 1))
      continue
    fi

    echo "[flux-validate] FAILED ${rel_dir}" >&2
    echo "${rendered}" >&2
    failed=1
    continue
  fi

  if [[ ${run_kubeconform} -eq 1 ]]; then
    if ! printf '%s\n' "${rendered}" | kubeconform "${kubeconform_flags[@]}" "${kubeconform_config[@]}"; then
      echo "[flux-validate] FAILED schema validation for ${rel_dir}" >&2
      failed=1
      continue
    fi
  fi

  validated=$((validated + 1))
done

echo "[flux-validate] summary: validated=${validated} skipped=${skipped}"
exit "${failed}"
