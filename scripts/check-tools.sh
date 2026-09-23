#!/usr/bin/env bash
# check-tools.sh - verify the workstation has everything the course labs need.
#
# Prints one line per tool: OK with the installed version, or MISSING / TOO OLD
# with where to get it. Exit code 1 when anything is missing, so it can gate
# other targets. Minimum versions are the ones the kind profile was verified
# with; newer is fine.
#
# Usage:
#   make check-tools
#   scripts/check-tools.sh
set -Eeuo pipefail

# Minimum versions (major.minor[.patch]); "" = any version.
MIN_TERRAFORM="1.5"
MIN_KIND="0.30"
MIN_KUBECTL="1.30"
MIN_FLUX="2.4"

FAIL=0
OS="$(uname -s)"

ok()      { printf '  \033[0;32mOK\033[0m       %-12s %s\n' "$1" "$2"; }
missing() { printf '  \033[0;31mMISSING\033[0m  %-12s %s\n' "$1" "$2"; FAIL=1; }
too_old() { printf '  \033[0;33mTOO OLD\033[0m  %-12s %s (need >= %s)\n' "$1" "$2" "$3"; FAIL=1; }

# Install hint per OS. Official docs first, then the package manager one-liner.
hint() {
  local tool="$1"
  case "$tool:$OS" in
    docker:Darwin)     echo "https://orbstack.dev (recommended) or https://docs.docker.com/desktop/" ;;
    docker:*)          echo "https://docs.docker.com/engine/install/" ;;
    terraform:Darwin)  echo "brew tap hashicorp/tap && brew install hashicorp/tap/terraform  | https://developer.hashicorp.com/terraform/install" ;;
    terraform:*)       echo "https://developer.hashicorp.com/terraform/install" ;;
    kind:Darwin)       echo "brew install kind  | https://kind.sigs.k8s.io/docs/user/quick-start/#installation" ;;
    kind:*)            echo "https://kind.sigs.k8s.io/docs/user/quick-start/#installation" ;;
    kubectl:Darwin)    echo "brew install kubectl  | https://kubernetes.io/docs/tasks/tools/" ;;
    kubectl:*)         echo "https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/" ;;
    flux:Darwin)       echo "brew install fluxcd/tap/flux  | https://fluxcd.io/flux/installation/" ;;
    flux:*)            echo "curl -s https://fluxcd.io/install.sh | sudo bash  | https://fluxcd.io/flux/installation/" ;;
    sops:Darwin)       echo "brew install sops  | https://github.com/getsops/sops/releases" ;;
    sops:*)            echo "https://github.com/getsops/sops/releases (download the binary for your arch)" ;;
    age-keygen:Darwin) echo "brew install age  | https://github.com/FiloSottile/age#installation" ;;
    age-keygen:*)      echo "apt install age  | https://github.com/FiloSottile/age#installation" ;;
    pre-commit:Darwin) echo "brew install pre-commit  | https://pre-commit.com/#install" ;;
    pre-commit:*)      echo "pip install pre-commit  | https://pre-commit.com/#install" ;;
    git:Darwin)        echo "xcode-select --install or brew install git" ;;
    git:*)             echo "apt install git" ;;
    make:Darwin)       echo "xcode-select --install" ;;
    make:*)            echo "apt install build-essential" ;;
    *)                 echo "" ;;
  esac
}

# version_ge "1.13.3" "1.5" -> true when the first is >= the second (numeric, dot-separated).
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# First "digits.digits[.digits]" in the tool's version output.
first_version() {
  grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# check <tool> <min> <command that prints the version>
check() {
  local tool="$1" min="$2" cmd="$3" ver
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing "$tool" "$(hint "$tool")"
    return
  fi
  ver="$(eval "$cmd" 2>/dev/null | first_version || true)"
  if [ -n "$min" ] && [ -n "$ver" ] && ! version_ge "$ver" "$min"; then
    too_old "$tool" "$ver" "$min"
    return
  fi
  ok "$tool" "${ver:-installed}"
}

echo "SafeOps lab tools ($OS)"
echo ""
check git        ""               "git --version"
check make       ""               "make --version"
check docker     ""               "docker --version"
check terraform  "$MIN_TERRAFORM" "terraform version"
check kind       "$MIN_KIND"      "kind version"
check kubectl    "$MIN_KUBECTL"   "kubectl version --client"
check flux       "$MIN_FLUX"      "flux version --client"
check sops       ""               "sops --version"
check age-keygen ""               "age-keygen --version"
check pre-commit ""               "pre-commit --version"

# Docker must not only be installed but running - the kind nodes are containers.
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker daemon" "running"
  else
    missing "docker daemon" "not running - start Docker Desktop / OrbStack / Colima, then re-run"
  fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All tools present. Continue with the lab setup."
else
  echo "Install or update the tools marked above, then run this again."
  exit 1
fi
