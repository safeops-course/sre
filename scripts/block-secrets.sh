#!/bin/bash
# pre-commit hook no-secrets: the hook's `files` pattern selects kubeconfigs, private keys (.key,
# .pem), credentials files and .env files; any staged file it passes here is refused.
echo "BLOCKED: sensitive file(s) staged for commit:" >&2
for f in "$@"; do echo "  $f" >&2; done
echo "Unstage them (git restore --staged <file>); keep credentials out of Git - see flux/secrets/README.md for secrets Flux needs." >&2
exit 1
