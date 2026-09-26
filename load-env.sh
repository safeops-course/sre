#!/usr/bin/env bash

# Load sensitive env vars from .env.local and SSH keys (without storing secrets in git).
# Usage: source ./load-env.sh

# Detect if the script is sourced (bash/zsh) so we can avoid closing the shell.
sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
  case ${ZSH_EVAL_CONTEXT} in *:file) sourced=1 ;; esac
elif [ -n "${BASH_VERSION:-}" ]; then
  [[ "${BASH_SOURCE[0]}" != "${0}" ]] && sourced=1
fi

if [ "${sourced}" -eq 0 ]; then
  echo "Warning: script not sourced; exports won't persist. Use: source ./load-env.sh"
fi

die() {
  echo "$1"
  if [ "${sourced}" -eq 1 ]; then
    return 1
  fi
  exit 1
}

# Resolve script's own directory so it works from any pwd
if [ -n "${ZSH_VERSION:-}" ]; then
  ROOT_DIR="${0:A:h}"
elif [ -n "${BASH_VERSION:-}" ]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  ROOT_DIR="$(pwd)"
fi
ENV_FILE="${ROOT_DIR}/.env.local"
SSH_PUB_PATH="${HOME}/.ssh/id_ed25519.pub"
SSH_PRIV_PATH="${HOME}/.ssh/id_ed25519"
AGE_PRIV_KEY="${HOME}/.ssh/age.agekey"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Create it with your secrets (not committed)."
  echo "Example keys:"
  echo "  SOPS_AGE_KEY=AGE-SECRET-KEY-..."
  echo "  R2_ACCESS_KEY_ID=<your-r2-access-key>"
  echo "  R2_SECRET_ACCESS_KEY=<your-r2-secret-key>"
  echo "  HCLOUD_TOKEN=<your-hcloud-token>"
  echo "  FLUX_GIT_TOKEN=github_pat_..."
  echo "  GHCR_TOKEN=ghp_..."
  echo "  BACKUP_S3_ACCESS_KEY_ID=<hetzner-object-storage-access-key>"
  echo "  BACKUP_S3_SECRET_ACCESS_KEY=<hetzner-object-storage-secret-key>"
  echo "  BACKUP_S3_ENDPOINT=https://nbg1.your-objectstorage.com"
  echo "  BACKUP_S3_REGION=nbg1"
  echo "  BACKUP_S3_BUCKET=<your-backup-bucket>"
  die "Aborting: ${ENV_FILE} not found."
fi

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

# Terraform env var wiring (so Terraform picks up secrets via TF_VAR_*)
export TF_VAR_ghcr_token="${GHCR_TOKEN:-}"
export TF_VAR_ghcr_username="${GHCR_USERNAME:-}"
export TF_VAR_flux_git_token="${FLUX_GIT_TOKEN:-}"
export TF_VAR_hcloud_token="${HCLOUD_TOKEN:-}"
# Terraform state backend (Cloudflare R2) - the only use of the R2 keys
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"

# CNPG and etcd backups (Hetzner Object Storage) - separate key, never the state key
export TF_VAR_backup_s3_access_key_id="${BACKUP_S3_ACCESS_KEY_ID:-}"
export TF_VAR_backup_s3_secret_access_key="${BACKUP_S3_SECRET_ACCESS_KEY:-}"
export TF_VAR_backup_s3_bucket="${BACKUP_S3_BUCKET:-}"
export TF_VAR_backup_s3_endpoint="${BACKUP_S3_ENDPOINT:-}"
export TF_VAR_backup_s3_region="${BACKUP_S3_REGION:-}"
export TF_VAR_enable_ghcr=true
export TF_VAR_flux_git_repository_url="https://github.com/safeops-course/sre.git"
export TF_VAR_uptrace_dsn="${UPTRACE_DSN:-}"

# Cloudflare Access / KV (for cloudflare_safeops Terraform)
export TF_VAR_cloudflare_api_token="${CLOUDFLARE_API_TOKEN:-}"
export TF_VAR_cloudflare_account_id="${CLOUDFLARE_ACCOUNT_ID:-}"

if [[ -f "${AGE_PRIV_KEY}" ]]; then
  TF_VAR_sops_age_key="$(grep -o 'AGE-SECRET-KEY-[a-zA-Z0-9]*' "${AGE_PRIV_KEY}")"
  export TF_VAR_sops_age_key
else
  echo "Missing Age private key at ${AGE_PRIV_KEY}"
fi

if [[ -f "${SSH_PUB_PATH}" ]]; then
  HCLOUD_SSH_PUBLIC_KEY="$(cat "${SSH_PUB_PATH}")"
  export HCLOUD_SSH_PUBLIC_KEY
  export TF_VAR_ssh_public_key="${HCLOUD_SSH_PUBLIC_KEY}"
else
  echo "Missing SSH public key at ${SSH_PUB_PATH}"
fi

# The node private key is never a Terraform variable (it would land in the plan and the state):
# kube-hetzner signs in through ssh-agent, so load the key there once.
if [[ -f "${SSH_PRIV_PATH}" ]]; then
  if ! ssh-add -l 2>/dev/null | grep -qF "$(ssh-keygen -lf "${SSH_PUB_PATH}" | awk '{print $2}')"; then
    ssh-add "${SSH_PRIV_PATH}" || die "Could not add ${SSH_PRIV_PATH} to ssh-agent - Terraform cannot reach the nodes"
  fi
else
  echo "Missing SSH private key at ${SSH_PRIV_PATH}"
fi

echo "Loaded env vars from ${ENV_FILE} and SSH keys from ~/.ssh."
