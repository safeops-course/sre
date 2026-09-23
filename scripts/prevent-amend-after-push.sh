#!/bin/bash
set -Eeuo pipefail

# Skip if not in git repo or no remotes or no commits
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
git remote 2>/dev/null | grep -q . || exit 0
git rev-parse HEAD >/dev/null 2>&1 || exit 0

# Only block amend operations ($2 == "commit" in prepare-commit-msg)
[[ "${2:-}" == "commit" ]] || exit 0

target_sha="${3:-HEAD}"

if git branch -r --contains "$target_sha" 2>/dev/null | grep -v '->' | grep -v 'origin/HEAD' | grep -q .; then
    echo ""
    echo "BLOCKED: Cannot amend commits that have been pushed!"
    echo "Remote branches containing this commit:"
    git branch -r --contains "$target_sha" 2>/dev/null | sed 's/^[[:space:]]*//' | grep -v '->' | grep -v 'origin/HEAD'
    echo ""
    echo "Create a new commit instead: git commit -m 'fix: ...'"
    echo ""
    exit 1
fi

exit 0
