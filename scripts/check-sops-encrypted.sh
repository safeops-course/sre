#!/usr/bin/env bash
# Fail if a Kubernetes manifest under flux/secrets/ is not SOPS-encrypted.
#
# A file passes when it has SOPS metadata (a top-level `sops:` key) and every value under `data:` /
# `stringData:` is an `ENC[...]` value. That catches a plaintext Secret, and a plaintext key added by
# hand to an already encrypted file (Flux would fail on it later with a MAC error).
# kustomization.yaml files and templates (*.example) are not secrets and are skipped.
#
# Used by the pre-commit hook `sops-encrypted` (staged files) and by CI (all files, because
# `git commit --no-verify` skips hooks).
#
# Usage: scripts/check-sops-encrypted.sh [FILE...]    # no FILE: every flux/secrets/**/*.yaml

set -Eeuo pipefail

cd "$(git rev-parse --show-toplevel)"

files=("$@")
if (( ${#files[@]} == 0 )); then
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files 'flux/secrets/**.yaml' 'flux/secrets/**.yml')
fi
if (( ${#files[@]} == 0 )); then
  echo "sops-encrypted: no files to check."
  exit 0
fi

failed=0
checked=0
for f in "${files[@]}"; do
  case "$f" in
    flux/secrets/*) ;;
    *) continue ;;
  esac
  case "$(basename "$f")" in
    kustomization.yaml | kustomization.yml | *.example) continue ;;
  esac
  [[ -f "$f" ]] || continue
  checked=$((checked + 1))

  if ! grep -q '^sops:' "$f"; then
    echo "NOT ENCRYPTED: $f has no SOPS metadata - encrypt it: sops --encrypt --in-place $f" >&2
    failed=1
    continue
  fi

  # Leaf values under the top-level data:/stringData: blocks must all be ENC[...].
  plain=$(awk '
    /^[^[:space:]#]/ { in_block = ($0 ~ /^(data|stringData):/) ; next }
    in_block && /^[[:space:]]+[^[:space:]#][^:]*:/ {
      value = $0
      sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "", value)
      if (value !~ /^ENC\[/) { key = $0; sub(/:.*/, "", key); gsub(/^[[:space:]]+/, "", key); print key }
    }
  ' "$f")
  if [[ -n "$plain" ]]; then
    echo "PLAINTEXT VALUE: $f - not encrypted: $(echo "$plain" | tr '\n' ' ')" >&2
    echo "  sops cannot decrypt a file with a plaintext value: delete those lines, then add the values with: sops edit $f" >&2
    failed=1
  fi
done

if (( failed )); then
  echo "Secrets under flux/secrets/ must be committed encrypted (see flux/secrets/README.md)." >&2
  exit 1
fi
echo "sops-encrypted: ${checked} secret file(s) checked, all encrypted."
