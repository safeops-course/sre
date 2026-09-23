#!/bin/bash
set -e

DEFAULT_PROTECTED=("master" "main")
PROTECTED_PATTERNS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --protected=*) PROTECTED_PATTERNS+=("${1#*=}"); shift ;;
        --protected)
            if [[ $# -ge 2 ]]; then
                PROTECTED_PATTERNS+=("$2"); shift 2
            else
                echo "Error: --protected requires a value" >&2; exit 1
            fi
            ;;
        *) shift ;;
    esac
done

if [ ${#PROTECTED_PATTERNS[@]} -eq 0 ]; then
    PROTECTED_PATTERNS=("${DEFAULT_PROTECTED[@]}")
fi

current_branch=$(git branch --show-current || true)
if [[ -z "$current_branch" ]]; then
    echo "Cannot determine current branch (detached HEAD). Aborting." >&2
    exit 1
fi

for pattern in "${PROTECTED_PATTERNS[@]}"; do
    # shellcheck disable=SC2053
    if [[ -n "$pattern" && "$current_branch" == $pattern ]]; then
        echo ""
        echo "COMMIT BLOCKED: Cannot commit directly to '$current_branch'"
        echo "Create a feature branch first: git checkout -b feature/your-task-name"
        echo ""
        exit 1
    fi
done

exit 0
