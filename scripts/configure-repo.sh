#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/configure-repo.sh --github-owner <owner> [--github-repo <repo>]

Updates hardcoded defaults in docs/ and flux/ to match your GitHub org/user and repo name.

Examples:
  scripts/configure-repo.sh --github-owner stan --github-repo sre
EOF
}

GITHUB_OWNER=""
GITHUB_REPO="sre"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-owner)
      GITHUB_OWNER="${2:-}"
      shift 2
      ;;
    --github-repo)
      GITHUB_REPO="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${GITHUB_OWNER}" ]]; then
  echo "--github-owner is required" >&2
  usage >&2
  exit 2
fi

OLD_OWNER="ldbl"
OLD_REPO="sre"

NEW_HTTPS_REPO_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"
NEW_SSH_REPO_URL="ssh://git@github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"

FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
  rg -l --fixed-strings \
    "github.com/${OLD_OWNER}/${OLD_REPO}.git" \
    "ghcr.io/${OLD_OWNER}/backend" \
    "ghcr.io/${OLD_OWNER}/frontend" \
    docs flux infra/terraform 2>/dev/null || true
)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "[configure-repo] nothing to update"
  exit 0
fi

echo "[configure-repo] updating ${#FILES[@]} file(s)"

for f in "${FILES[@]}"; do
  # repo URLs
  perl -pi -e "s#https://github\\.com/${OLD_OWNER}/${OLD_REPO}\\.git#${NEW_HTTPS_REPO_URL}#g" "$f"
  perl -pi -e "s#ssh://git@github\\.com/${OLD_OWNER}/${OLD_REPO}\\.git#${NEW_SSH_REPO_URL}#g" "$f"

  # GHCR images
  perl -pi -e "s#ghcr\\.io/${OLD_OWNER}/backend#ghcr.io/${GITHUB_OWNER}/backend#g" "$f"
  perl -pi -e "s#ghcr\\.io/${OLD_OWNER}/frontend#ghcr.io/${GITHUB_OWNER}/frontend#g" "$f"
done

echo "[configure-repo] done"

