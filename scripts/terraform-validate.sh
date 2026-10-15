#!/bin/bash
set -e
# terraform-validate.sh - pre-commit hook terraform-validate (runs when a .tf or .tfvars file is
# staged); `make validate` and the Pre-commit CI job run it too.
#
# Validate every Terraform module the course uses: the local kind cluster
# (core track), the Hetzner cluster (cloud track), the Google Cloud foundation and the state lab.
# Usage: scripts/terraform-validate.sh   (from the repository root). Needs terraform; changes no
# state and no cluster.
#
# Each module is initialised in its own throw-away TF_DATA_DIR with
# -backend=false: validate needs the providers and modules, never the state.
# The module's real .terraform/ is not touched, so a directory that was once
# initialised against a remote backend (R2) does not make validate read that
# backend - or fail on whatever cloud credentials happen to be in the shell.
# The trap removes the current module's data dir also when init or validate
# fails (set -e exits before the rm below); each dir holds the providers.
#
# Providers are downloaded once into a shared plugin cache (TF_PLUGIN_CACHE_DIR, default
# ~/.terraform.d/plugin-cache) and linked from there. Without it every run downloaded every provider
# of all three modules again - half a minute per commit, and one flaky download from GitHub failed
# the hook (found in the Chapter 05 lab, 2026-10-04).
# A git hook runs with GIT_INDEX_FILE (and GIT_DIR, GIT_WORK_TREE) set to the commit's own - with
# `git commit -a` a temporary index. terraform init downloads registry modules with git clone, which
# inherits them: kube-hetzner's files landed in the commit's index and the commit failed ("invalid
# object ... for '.claude/skills/debug-node/SKILL.md'"). The modules' git must see its own repository.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_PREFIX

export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${HOME}/.terraform.d/plugin-cache}"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

# Terraform does not guarantee that the plugin cache is safe for two inits at once (a commit hook
# and `make validate` in another terminal). One run at a time holds a lock directory next to the
# cache: mkdir is atomic, and unlike flock it exists on macOS and Linux. The lock records the PID of
# its owner. A lock is reclaimed only when that process no longer exists (a killed run); a live
# owner is waited for, up to 5 minutes. On exit a run removes the lock only if it is still its own.
lock_dir="${TF_PLUGIN_CACHE_DIR}.lock"
lock_held=""
waited=0
until mkdir "${lock_dir}" 2>/dev/null; do
  owner="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
  # No pid yet: the owner is between mkdir and writing it - wait like for any owner.
  if [ -n "${owner}" ] && ! ps -p "${owner}" >/dev/null 2>&1; then
    echo "terraform-validate: reclaiming the lock of a run that is gone (pid ${owner})" >&2
    # Move it away first (atomic), so two waiting runs cannot both reclaim it.
    if mv "${lock_dir}" "${lock_dir}.stale.$$" 2>/dev/null; then
      rm -rf "${lock_dir}.stale.$$"
    fi
    continue
  fi
  if [ "${waited}" -ge 300 ]; then
    echo "terraform-validate: pid ${owner:-?} holds ${lock_dir} for 5 minutes - giving up" >&2
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done
echo "$$" > "${lock_dir}/pid"
lock_held=1

# release_lock - remove the lock only if it still records this run's PID.
release_lock() {
  if [ -n "${lock_held}" ] && [ "$(cat "${lock_dir}/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "${lock_dir}"
  fi
}

data_dir=""
# On every exit: the current module's data dir (init or validate may fail) and the lock.
trap 'if [ -n "${data_dir}" ]; then rm -rf "${data_dir}"; fi; release_lock' EXIT
for dir in infra/terraform/kind_cluster infra/terraform/hcloud_cluster infra/terraform/gcp_foundation infra/terraform/state-lab; do
  echo "terraform validate: ${dir}"
  data_dir="$(mktemp -d)"
  TF_DATA_DIR="${data_dir}" terraform -chdir="${dir}" init -input=false -backend=false >/dev/null
  TF_DATA_DIR="${data_dir}" terraform -chdir="${dir}" validate
  rm -rf "${data_dir}"
  data_dir=""
done
