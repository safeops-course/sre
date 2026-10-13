#!/usr/bin/env bash
# Tests scripts/capstone-fault.sh in a throw-away repository - no cluster, no GitHub. For each fault:
# a fresh copy of flux/ and scripts/, then `capstone-fault.sh --local` with that fault chosen, and
# three questions: did it make exactly one commit, by the colleague, on a new branch; does the change
# say what the fault is meant to say (one grep each); and does it still pass the platform's own
# checks (check-app-security.sh, check-app-resources.sh) - a fault the pull request checks catch
# would never reach the cluster, and the capstone would have nothing to find.
# The GitHub path runs too, against a local bare repository as origin and a stub gh that logs its calls
# and answers like GitHub: it pushes, opens and merges, names the repository in every gh call, refuses
# a repository that is not a fork or a branch left on origin, and leaves no worktree or local branch.
# Run: tests/capstone-fault.test.sh   (pre-commit runs it when the script, this test or a file a
# fault edits changes - so an edit that breaks a fault fails here, not in a learner's capstone)
# Needs git, yq (v4) and kubectl (kustomize), like the checks. Exit 0 when every case passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# This test guards the course repository: that each fault still applies to its main. In a learner's
# fork it must not run - CI there runs every hook on every file, and during the capstone the fork's
# main holds the fault itself (it cannot be made again) and the learner's own edits of those lines.
# There it would fail every pull request, the colleague's included. Found in a real run on a fork.
COURSE_REPOSITORY="safeops-course/sre"
origin_url="$(git -C "${ROOT}" remote get-url origin 2>/dev/null || echo "none")"
# OWNER/NAME from the URL, compared whole: safeops-course/sre-course is not safeops-course/sre.
origin_repo="$(sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#' <<<"${origin_url}")"
if [[ "${origin_repo}" != "${COURSE_REPOSITORY}" ]]; then
  echo "skip - not the course repository (origin: ${origin_url}); the faults are checked there"
  exit 0
fi
# A git hook (pre-commit) exports GIT_INDEX_FILE and friends for this repository; the throw-away
# repositories below must not inherit them - a worktree there would open this repository's index.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# fresh_repo - ${WORK}/repo: a git repository with this repository's flux/ and scripts/, one commit.
# Its own identity, no signing and no hooks - the test must not depend on the machine's git setup.
fresh_repo() {
  local repo="${WORK}/repo"
  rm -rf "${repo}"
  mkdir -p "${repo}"
  cp -R "${ROOT}/flux" "${ROOT}/scripts" "${repo}/"
  git -C "${repo}" init -q -b main
  git -C "${repo}" config user.name test
  git -C "${repo}" config user.email test@example.invalid
  git -C "${repo}" config commit.gpgsign false
  git -C "${repo}" config core.hooksPath /dev/null
  git -C "${repo}" add -A
  git -C "${repo}" commit -q -m base
}

# check NAME COMMAND... - one assertion: the command succeeds. A call without a command fails.
check() {
  local name="$1"
  if [[ $# -lt 2 ]]; then
    echo "FAIL - ${name}: no command to check"
    FAILED=1
    return
  fi
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}"
    FAILED=1
  fi
}

# run_fault FAULT EXPECTED_DIFF_REGEX - make FAULT in a fresh copy and check it.
run_fault() {
  local fault="$1" expected="$2" repo="${WORK}/repo"
  fresh_repo
  if ! CAPSTONE_FAULT="${fault}" "${repo}/scripts/capstone-fault.sh" --local >"${WORK}/out" 2>&1; then
    echo "FAIL - ${fault}: capstone-fault.sh --local failed:"
    sed 's/^/       /' "${WORK}/out"
    FAILED=1
    return
  fi
  check "${fault}: one commit on a new branch" \
    test "$(git -C "${repo}" rev-list --count main..HEAD)" -eq 1
  check "${fault}: authored by the colleague" \
    grep -q 'Mira Koleva' <<<"$(git -C "${repo}" log -1 --format=%an)"
  check "${fault}: the change is the fault" \
    grep -Eq "${expected}" <<<"$(git -C "${repo}" show --format= -U0 HEAD)"
  check "${fault}: the working copy is clean" \
    test -z "$(git -C "${repo}" status --porcelain)"
  check "${fault}: passes check-app-security.sh" "${repo}/scripts/check-app-security.sh"
  check "${fault}: passes check-app-resources.sh" "${repo}/scripts/check-app-resources.sh"
}

run_fault f1 '^\+ +value: "1"$'
run_fault f2 '^\+ +values: \[app-postgres-rw\]$'
run_fault f3 '^\+ +cpu: 25m$'

# An unknown fault is refused, and nothing is committed.
fresh_repo
check "an unknown fault is refused" \
  bash -c "! CAPSTONE_FAULT=f9 '${WORK}/repo/scripts/capstone-fault.sh' --local"
check "  - and nothing changed" test "$(git -C "${WORK}/repo" rev-list --count HEAD)" -eq 1

# A branch that exists already is refused, and the checkout is left as it was.
fresh_repo
CAPSTONE_FAULT=f1 "${WORK}/repo/scripts/capstone-fault.sh" --local >/dev/null 2>&1
git -C "${WORK}/repo" switch -q main
check "an existing branch is refused" \
  bash -c "! CAPSTONE_FAULT=f1 '${WORK}/repo/scripts/capstone-fault.sh' --local"
check "  - and the checkout is clean, still on main" \
  test "$(git -C "${WORK}/repo" status --porcelain)$(git -C "${WORK}/repo" branch --show-current)" = main

# --- the GitHub path, with origin a local bare repository and a stub gh ---

# stub_gh - ${WORK}/bin/gh: logs each call to ${STUB_LOG}; is-fork and merge answers from
# STUB_FORK (default true) and STUB_MERGE_RC (default 0); STUB_CHECKS=none answers like a fork whose
# Actions are off. Also ${WORK}/bin/ssh, for ssh -G only:
# the alias github-alias resolves to github.com, any other host to itself - the machine's ssh config
# must not decide the test.
stub_gh() {
  mkdir -p "${WORK}/bin"
  cat >"${WORK}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-G" ]] || { echo "stub ssh: only -G" >&2; exit 1; }
if [[ "$2" == "github-alias" ]]; then echo "hostname github.com"; else echo "hostname $2"; fi
STUB
  chmod +x "${WORK}/bin/ssh"
  cat >"${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}"
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "${STUB_FORK:-true}" ;;
  "pr create") echo "https://github.com/learner/sre/pull/1" ;;
  "pr checks")
    if [[ "${STUB_CHECKS:-}" == "none" ]]; then echo "no checks reported on the 'x' branch"; exit 1; fi
    echo "all checks passed" ;;
  "pr merge") exit "${STUB_MERGE_RC:-0}" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "${WORK}/bin/gh"
}

# github_repo_with_origin [URL] - fresh_repo plus an origin at URL (default
# https://github.com/learner/sre.git) that git sends to the local bare ${WORK}/learner/sre.git
# (url.insteadOf): the script sees a GitHub URL, the push stays on this machine.
github_repo_with_origin() {
  local url="${1:-https://github.com/learner/sre.git}"
  fresh_repo
  rm -rf "${WORK}/learner" "${WORK}/gh.log"
  mkdir -p "${WORK}/learner"
  git clone -q --bare "${WORK}/repo" "${WORK}/learner/sre.git"
  git -C "${WORK}/repo" config "url.${WORK}/learner/sre.git.insteadOf" "${url}"
  git -C "${WORK}/repo" remote add origin "${url}"
  git -C "${WORK}/repo" fetch -q origin
}

# run_github_fault - capstone-fault.sh without --local, f1, the stub gh first in PATH.
run_github_fault() {
  PATH="${WORK}/bin:${PATH}" STUB_LOG="${WORK}/gh.log" CAPSTONE_FAULT=f1 CAPSTONE_POLL_SECONDS=0 \
    "${WORK}/repo/scripts/capstone-fault.sh" >"${WORK}/out" 2>&1
}

# expect_refused NAME - run_github_fault must fail (the caller sets the stub's answers before it).
expect_refused() {
  if run_github_fault; then
    echo "FAIL - $1"
    FAILED=1
  else
    echo "ok   - $1"
  fi
}

# no_worktree_left - only the repository itself is a worktree.
# shellcheck disable=SC2329  # called through check
no_worktree_left() { test "$(git -C "${WORK}/repo" worktree list | wc -l)" -eq 1; }

stub_gh
github_repo_with_origin
if run_github_fault; then
  echo "ok   - github: exits 0"
else
  echo "FAIL - github: exits 0:"
  sed 's/^/       /' "${WORK}/out"
  FAILED=1
fi
check "github: the colleague's branch is on origin" \
  grep -q 'Mira Koleva' <<<"$(git -C "${WORK}/learner/sre.git" log -1 --format=%an fix/signup-bots 2>&1)"
check "github: no local branch left" \
  test -z "$(git -C "${WORK}/repo" branch --list fix/signup-bots)"
check "github: no worktree left" no_worktree_left
check "github: the checkout is clean, still on main" \
  test "$(git -C "${WORK}/repo" status --porcelain)$(git -C "${WORK}/repo" branch --show-current)" = main
check "github: every pull request call names the fork" \
  test "$(grep -c '^pr ' "${WORK}/gh.log")" -eq "$(grep -c '^pr .*--repo learner/sre' "${WORK}/gh.log")"

expect_refused "github: a branch left on origin is refused"
check "  - for that reason" grep -q 'from an earlier run' "${WORK}/out"
check "  - and no worktree left" no_worktree_left

github_repo_with_origin
STUB_FORK=false expect_refused "github: a repository that is not a fork is refused"
check "  - and nothing pushed" \
  bash -c "! git -C '${WORK}/learner/sre.git' rev-parse -q --verify fix/signup-bots"

github_repo_with_origin https://gitlab.example/learner/sre.git
expect_refused "github: an origin that is not on GitHub is refused"
check "  - and says so" grep -q 'is not github.com' "${WORK}/out"
check "  - and nothing pushed" \
  bash -c "! git -C '${WORK}/learner/sre.git' rev-parse -q --verify fix/signup-bots"

github_repo_with_origin https://github-alias/learner/sre.git
expect_refused "github: an https origin on an ssh alias is refused (https does not read ssh aliases)"
check "  - and says so" grep -q 'is not github.com' "${WORK}/out"

github_repo_with_origin git@github-alias:learner/sre.git
if run_github_fault; then
  echo "ok   - github: an ssh origin on an alias for github.com works"
else
  echo "FAIL - github: an ssh origin on an alias for github.com works:"
  sed 's/^/       /' "${WORK}/out"
  FAILED=1
fi

github_repo_with_origin
STUB_CHECKS=none expect_refused "github: no checks at all - nothing is merged"
check "  - and says to enable Actions" grep -q 'Enable Actions in your fork' "${WORK}/out"
check "  - and never calls merge" bash -c "! grep -q '^pr merge' '${WORK}/gh.log'"
check "  - and no worktree left" no_worktree_left

github_repo_with_origin
STUB_MERGE_RC=1 expect_refused "github: a refused merge fails"
check "  - and says what to do" grep -q 'the pull request is open' "${WORK}/out"
check "  - and no worktree left" no_worktree_left

exit "${FAILED}"
