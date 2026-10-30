#!/usr/bin/env bash
# capstone-fault.sh - a colleague's pull request for the Chapter 23 capstone: one plausible change
# that passes every check and still breaks the platform for its users.
#
# Why: the capstone asks for one change proven in staging and production while the platform is not
# quiet - like every real week, someone else merges something too. This script plays that colleague:
# it picks one of three faults at random, commits it with the message the colleague would write,
# opens a pull request in your repository and leaves it for review after its checks pass. The faults
# (each verified on kind: it passes CI, it breaks, a revert through Git fixes it):
#   f1  sign-ups limited to one a minute (AUTH_REGISTRATIONS_PER_MINUTE) - the pods stay Ready, no
#       alert fires, most sign-ups get 429;
#   f2  the database network policies select a label value no pod has - nothing breaks until the
#       next rollout; then the new backend pods wait at Init for a database they cannot reach;
#   f3  backend CPU cut to 25m - everything works, sign-ups and sign-ins take seconds.
# Which one is not printed: finding it from its symptoms is the exercise. The commit stays in your
# history, like any colleague's.
#
# Usage: make capstone-fault
#        scripts/capstone-fault.sh             (the same)
#        scripts/capstone-fault.sh --local     (commit on a new branch here; no push, no pull request -
#                                               tests, or a repository without GitHub)
#        CAPSTONE_FAULT=f2 scripts/capstone-fault.sh ...   (a chosen fault instead of a random one)
# Needs git; without --local also gh, logged in, a clean main equal to origin/main, and an origin that
# is a fork on GitHub (yours). CAPSTONE_POLL_SECONDS (default 10) is the wait between check polls - for tests.
# Changes: without --local a branch and an open pull request in your GitHub repository. A person
# reviews and explicitly merges it before Flux applies the fault. Your working copy is not touched:
# the change is made in a temporary git worktree. With --local, a new branch with one commit in this repository.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The colleague. Fictional: the author of the commit, never a GitHub account.
COLLEAGUE="Mira Koleva <mira.koleva@colleague.invalid>"

# die MESSAGE - print the reason and stop.
die() {
  echo "capstone-fault: $*" >&2
  exit 1
}

# fault_f1 / fault_f2 / fault_f3 - make the fault's change in the current directory (a repository
# root) and set BRANCH, TITLE and BODY: what the colleague would name and write.

fault_f1() {
  local file=flux/apps/backend/base/deployment.yaml
  # Two lines after AUTH_REGISTRATION_ENABLED's value, in the same indentation.
  awk '{ print }
    prev ~ /- name: AUTH_REGISTRATION_ENABLED$/ {
      print "        - name: AUTH_REGISTRATIONS_PER_MINUTE   # bots signed up in bursts - one a minute is plenty"
      print "          value: \"1\""
    }
    { prev = $0 }' "${file}" > "${file}.new"
  mv "${file}.new" "${file}"
  BRANCH="fix/signup-bots"
  TITLE="fix(backend): limit sign-ups to one a minute against bot registrations"
  BODY="We saw bursts of bot sign-ups in the logs. Real people sign up a few times a day, so one a minute per pod is plenty and stops the bursts."
}

fault_f2() {
  local file
  # The Service's name (app-postgres-rw) where the pods' label value (app-postgres) belongs.
  for file in flux/infrastructure/network-policies/base/allow-backend-egress-postgres.yaml \
              flux/infrastructure/network-policies/base/allow-postgres-ingress-backend.yaml; do
    sed 's/values: \[app-postgres, app-postgres-restore\]/values: [app-postgres-rw]/' "${file}" > "${file}.new"
    mv "${file}.new" "${file}"
  done
  BRANCH="chore/netpol-postgres-name"
  TITLE="chore(network-policies): select postgres by its rw name, drop the restore leftover"
  BODY="The backend connects to app-postgres-rw, so the policies now name that. The restore entry was left over from the backup chapter and is not needed any more."
}

fault_f3() {
  local base=flux/apps/backend/base/deployment.yaml develop=flux/apps/backend/develop/kustomization.yaml
  # Only the backend container's CPU - the migrate initContainer above it keeps its own.
  awk '/^      - name: backend$/ { in_backend = 1 }
    in_backend && /cpu: 100m$/ { sub(/100m$/, "25m") }
    in_backend && /cpu: 250m$/ { sub(/250m$/, "25m") }
    { print }' "${base}" > "${base}.new"
  mv "${base}.new" "${base}"
  # Develop's own values, so develop stays no larger than staging and production.
  sed -e 's/value: "50m"/value: "25m"/' -e 's/value: "200m"/value: "25m"/' "${develop}" > "${develop}.new"
  mv "${develop}.new" "${develop}"
  BRANCH="chore/backend-right-size"
  TITLE="chore(backend): right-size CPU - kubectl top shows 1m per pod"
  BODY="kubectl top shows the backend at about 1m CPU per pod. 25m is still 25 times that, and frees the quota for other work."
}

# make_fault - run the chosen (or a random) fault and check that it changed something.
make_fault() {
  local fault="${CAPSTONE_FAULT:-}"
  if [[ -z "${fault}" ]]; then
    fault="f$((RANDOM % 3 + 1))"
  fi
  case "${fault}" in
    f1|f2|f3) "fault_${fault}" ;;
    *) die "CAPSTONE_FAULT must be f1, f2 or f3 (got '${fault}')" ;;
  esac
  [[ -n "$(git status --porcelain)" ]] || die "the change did not apply - has the file changed since this script was written?"
}

# commit_fault - commit everything changed, as the colleague.
commit_fault() {
  git add -A
  git commit -q --author="${COLLEAGUE}" -m "${TITLE}" -m "${BODY}"
}

# run_local - a new branch with the fault, in this repository.
run_local() {
  cd "${repo_root}"
  [[ -z "$(git status --porcelain)" ]] || die "the working copy has uncommitted changes - commit or stash them first"
  make_fault
  # BRANCH is known only after the fault: when it exists already, undo the fault's edits (the tree
  # was clean) so the checkout is left as it was.
  if ! git switch -q -c "${BRANCH}" 2>/dev/null; then
    git checkout -q -- .
    die "branch ${BRANCH} exists already - delete it (git branch -D ${BRANCH}) or choose another fault"
  fi
  commit_fault
  echo "capstone-fault: committed on branch ${BRANCH} (not pushed)"
}

# The temporary worktree of run_github. Global, not local: the EXIT trap runs after run_github has
# returned, when a local variable no longer exists (and set -u would stop the cleanup).
WORK=""

# cleanup - remove run_github's temporary worktree, if there is one.
cleanup() {
  [[ -n "${WORK}" ]] || return 0
  git -C "${repo_root}" worktree remove --force "${WORK}" >/dev/null 2>&1 || rm -rf "${WORK}"
  git -C "${repo_root}" worktree prune
}

# github_repo - origin's GitHub repository as OWNER/NAME, from an https, ssh:// or scp-like URL. Its
# host must be github.com; over ssh also an alias for it (Host github-me / HostName github.com) - an
# ssh alias means nothing to https, which resolves the name in DNS. gh looks the name up on GitHub,
# and it must be the repository git pushes to.
github_repo() {
  local url host path resolved transport
  url="$(git -C "${repo_root}" config --get remote.origin.url)"
  case "${url}" in
    https://*) transport=https; host="${url#*://}"; host="${host#*@}"; host="${host%%/*}"; path="${url#*://*/}" ;;
    ssh://*) transport=ssh; host="${url#*://}"; host="${host#*@}"; host="${host%%/*}"; path="${url#*://*/}" ;;
    *@*:*) transport=ssh; host="${url#*@}"; host="${host%%:*}"; path="${url#*:}" ;;
    *) die "origin (${url}) is not a GitHub URL - the capstone runs in your fork on GitHub" ;;
  esac
  host="${host%%:*}"   # host:port
  if [[ "${host}" != "github.com" && "${transport}" == "https" ]]; then
    die "origin's host ${host} is not github.com - the capstone runs in your fork on GitHub"
  fi
  if [[ "${host}" != "github.com" ]]; then
    resolved="$(ssh -G "${host}" 2>/dev/null | awk '$1 == "hostname" { print $2 }')"
    [[ "${resolved}" == "github.com" ]] \
      || die "origin's host ${host} is not github.com - the capstone runs in your fork on GitHub"
  fi
  echo "${path%.git}"
}

# run_github - the fault as a pull request in your GitHub repository, left open for review.
run_github() {
  command -v gh >/dev/null || die "gh is required (make check-tools), or use --local"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
  cd "${repo_root}"
  git fetch -q origin main
  [[ "$(git rev-parse main)" == "$(git rev-parse origin/main)" ]] \
    || die "your main is not origin/main - git switch main && git pull, then run it again"

  # Every gh call names the repository: in a fork, gh's default repository can be the upstream one
  # (Chapter 16 sets it), and the colleague's change belongs in your fork - never in the course's.
  local repo pr checks
  repo="$(github_repo)"
  [[ "$(gh repo view "${repo}" --json isFork --jq .isFork)" == "true" ]] \
    || die "origin (${repo}) is not a fork - the capstone runs in your fork of the platform repository"

  WORK="$(mktemp -d)"
  trap cleanup EXIT
  git worktree add -q --detach "${WORK}" origin/main
  cd "${WORK}"
  make_fault
  # A branch of the same name left on origin by an earlier run would refuse the push.
  # ls-remote --exit-code: 0 the branch exists, 2 it does not, anything else - origin did not answer.
  local found=0
  git ls-remote --exit-code --heads origin "${BRANCH}" >/dev/null || found=$?
  case "${found}" in
    0) die "origin has a branch ${BRANCH} from an earlier run - close its pull request with gh pr close <number> --repo ${repo} --delete-branch, or delete it: git push origin --delete ${BRANCH}" ;;
    2) ;;
    *) die "could not read origin's branches (git ls-remote exit ${found}) - is the network up?" ;;
  esac
  commit_fault
  # Pushed from the detached worktree: no local branch is left behind, so the same fault can run again.
  local pushed
  pushed="$(git push -q origin "HEAD:refs/heads/${BRANCH}" 2>&1)" || die "the push failed: ${pushed}"
  pr="$(gh pr create --repo "${repo}" --base main --head "${BRANCH}" --title "${TITLE}" --body "${BODY}")"
  echo "capstone-fault: a colleague opened ${pr}"

  # Wait for the repository's checks, as you would for your own pull request (Chapter 05).
  # They take a few seconds to appear after the pull request; until then gh pr checks says "no checks
  # reported". None after a minute and a half means Actions are off in the fork: then nothing is
  # merged - the colleague's change passes the same checks as yours, or it does not land (Chapter 05).
  for _ in 1 2 3 4 5 6 7 8 9; do
    sleep "${CAPSTONE_POLL_SECONDS:-10}"
    if checks="$(gh pr checks "${pr}" --repo "${repo}" 2>&1)"; then break; fi   # 0: there are checks, all passed
    grep -q 'no checks reported' <<<"${checks}" || break
  done
  if grep -q 'no checks reported' <<<"${checks}"; then
    die "no checks on ${pr} after a minute and a half - nothing merged. Enable Actions in your fork (its Actions tab) and keep Chapter 05's ruleset, then close this pull request (gh pr close ${pr} --repo ${repo} --delete-branch) and run this again"
  fi
  gh pr checks "${pr}" --repo "${repo}" --watch >/dev/null \
    || die "the pull request's checks failed - nothing merged: ${pr}"
  echo "capstone-fault: checks passed; the pull request is open for review: ${pr}"
  echo "Review it and record your sign-off as a pull request comment (GitHub does not let you approve your own pull request), then merge it yourself."
  echo "Only if your fork's ruleset requires an approving review, ask an authorized reviewer. Do not bypass repository rules."
  echo "After the merge, wait for Flux to apply main, then continue the capstone."
}

case "${1:-}" in
  --local) run_local ;;
  "") run_github ;;
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' ;;
  *) die "unknown argument '$1' (see --help)" ;;
esac
