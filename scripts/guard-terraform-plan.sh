#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/guard-terraform-plan.sh plan  --dir <path> [--out <planfile>]
  scripts/guard-terraform-plan.sh apply --dir <path> [--out <planfile>] [--max-age-minutes <n>]

Guardrail wrapper for Terraform plan/apply.
- `plan` creates a planfile and metadata marker.
- `apply` refuses to run unless a fresh planfile + metadata marker exist.

Examples:
  scripts/guard-terraform-plan.sh plan --dir infra/terraform/hcloud_cluster --out tfplan
  scripts/guard-terraform-plan.sh apply --dir infra/terraform/hcloud_cluster --out tfplan --max-age-minutes 60
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage >&2
  exit 0
fi

MODE="$1"
shift

WORKDIR=""
PLAN_FILE="tfplan"
MAX_AGE_MINUTES="120"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    --out)
      PLAN_FILE="${2:-}"
      shift 2
      ;;
    --max-age-minutes)
      MAX_AGE_MINUTES="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[guard-tf] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${WORKDIR}" ]]; then
  echo "[guard-tf] --dir is required" >&2
  usage >&2
  exit 2
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "[guard-tf] terraform not found in PATH" >&2
  exit 1
fi

if ! [[ -d "${WORKDIR}" ]]; then
  echo "[guard-tf] directory not found: ${WORKDIR}" >&2
  exit 1
fi

PLAN_PATH="${WORKDIR}/${PLAN_FILE}"
META_PATH="${PLAN_PATH}.meta"

case "${MODE}" in
  plan)
    terraform -chdir="${WORKDIR}" init -input=false
    terraform -chdir="${WORKDIR}" plan -input=false -lock-timeout=5m -out "${PLAN_FILE}"
    {
      echo "created_at_epoch=$(date +%s)"
      echo "workdir=${WORKDIR}"
      echo "plan_file=${PLAN_FILE}"
    } > "${META_PATH}"
    echo "[guard-tf] plan created: ${PLAN_PATH}"
    echo "[guard-tf] metadata created: ${META_PATH}"
    ;;
  apply)
    if [[ ! -f "${PLAN_PATH}" ]]; then
      echo "[guard-tf] missing plan file: ${PLAN_PATH}" >&2
      echo "[guard-tf] run: scripts/guard-terraform-plan.sh plan --dir ${WORKDIR} --out ${PLAN_FILE}" >&2
      exit 1
    fi
    if [[ ! -f "${META_PATH}" ]]; then
      echo "[guard-tf] missing plan metadata: ${META_PATH}" >&2
      echo "[guard-tf] refusing apply without plan marker" >&2
      exit 1
    fi

    # shellcheck disable=SC1090
    source "${META_PATH}"
    NOW_EPOCH="$(date +%s)"
    AGE_SECONDS="$((NOW_EPOCH - created_at_epoch))"
    AGE_MINUTES="$((AGE_SECONDS / 60))"

    if (( AGE_MINUTES > MAX_AGE_MINUTES )); then
      echo "[guard-tf] plan is too old (${AGE_MINUTES}m > ${MAX_AGE_MINUTES}m)" >&2
      echo "[guard-tf] re-run plan before apply" >&2
      exit 1
    fi

    terraform -chdir="${WORKDIR}" apply -input=false "${PLAN_FILE}"
    echo "[guard-tf] apply completed using ${PLAN_PATH}"
    ;;
  *)
    echo "[guard-tf] unknown mode: ${MODE}" >&2
    usage >&2
    exit 2
    ;;
esac
