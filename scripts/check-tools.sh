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
#
# Run by hand in Chapter 00, right after cloning. Needs only bash and the tools it checks;
# runs on macOS (bash 3.2) and Linux. Changes nothing - it only reads versions and `docker info`.
set -Eeuo pipefail

# Minimum versions (major.minor[.patch]); "" = any version.
MIN_TERRAFORM="1.11"   # the kind and Hetzner modules need write-only attributes (data_wo)
MIN_KIND="0.30"
MIN_KUBECTL="1.35"
MIN_FLUX="2.4"
MIN_COSIGN="3.0"     # Chapter 17 verifies Sigstore bundles stored as OCI referrers - checked with cosign 3
MIN_KYVERNO="1.19"   # tests/kyverno-policies.test.sh: 1.17 lets a wrong expectation pass
MIN_PROMTOOL="3.0"   # tests/platform-alerts.test.sh - the clusters run Prometheus 3
MIN_HELM="3.0"       # tests/tool-versions.test.sh asks the pinned charts what they install (helm show)
# Checkov: the version CI runs (.github/workflows/pre-commit.yml) - an older one can pass a scan CI fails.
MIN_CHECKOV="$(sed -n 's/.*checkov==\([0-9.]*\).*/\1/p' "$(dirname "$0")/../.github/workflows/pre-commit.yml")"

# Resources Docker gives the kind nodes. Measured on the full local profile:
# ~5.1 GiB used and ~0.4 cores busy at rest, ~2.7 cores requested. Labs add
# more (Ch11 restores a second Postgres, Ch08 OOM drills), so 8 GB is the floor.
MIN_DOCKER_CPUS=4
MIN_DOCKER_MEM_GIB=7.5   # "8 GB" in Docker Desktop / OrbStack reports slightly less
REC_DOCKER_MEM_GIB=12

FAIL=0
OS="$(uname -s)"

# Result lines: ok / missing / too_old / too_low <name> <detail> [<needed>]. Every failure sets FAIL=1.
ok()      { printf '  \033[0;32mOK\033[0m       %-12s %s\n' "$1" "$2"; }
missing() { printf '  \033[0;31mMISSING\033[0m  %-12s %s\n' "$1" "$2"; FAIL=1; }
too_old() { printf '  \033[0;33mTOO OLD\033[0m  %-12s %s (need >= %s)\n' "$1" "$2" "$3"; FAIL=1; }
too_low() { printf '  \033[0;33mTOO LOW\033[0m  %-12s %s (need >= %s)\n' "$1" "$2" "$3"; FAIL=1; }

# Install hint per OS. Official docs first, then the package manager one-liner.
hint() {
  local tool="$1"
  case "$tool:$OS" in
    docker:Darwin)     echo "https://orbstack.dev (recommended) or https://docs.docker.com/desktop/" ;;
    docker:*)          echo "https://docs.docker.com/engine/install/" ;;
    buildx:Darwin)     echo "comes with Docker Desktop / OrbStack; otherwise brew install docker-buildx | https://docs.docker.com/build/install-buildx/" ;;
    buildx:*)          echo "https://docs.docker.com/build/install-buildx/ (comes with Docker Engine from Docker's own packages)" ;;
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
    checkov:*)         echo "uv tool install checkov==${MIN_CHECKOV} (or pipx / pip; Homebrew lags behind)  | https://www.checkov.io/2.Basics/Installing%20Checkov.html" ;;
    gh:Darwin)         echo "brew install gh | https://cli.github.com/" ;;
    gh:*)              echo "https://github.com/cli/cli#installation" ;;
    git:Darwin)        echo "xcode-select --install or brew install git" ;;
    git:*)             echo "apt install git" ;;
    make:Darwin)       echo "xcode-select --install" ;;
    make:*)            echo "apt install build-essential" ;;
    jq:Darwin)         echo "brew install jq  | https://jqlang.org/download/" ;;
    jq:*)              echo "apt install jq  | https://jqlang.org/download/" ;;
    yq:Darwin)         echo "brew install yq  | https://github.com/mikefarah/yq#install" ;;
    yq:*)              echo "https://github.com/mikefarah/yq#install (the Go yq v4 - not the Python 'yq' from apt)" ;;
    cosign:Darwin)     echo "brew install cosign  | https://docs.sigstore.dev/cosign/system_config/installation/" ;;
    cosign:*)          echo "https://github.com/sigstore/cosign/releases (cosign-linux-amd64) | https://docs.sigstore.dev/cosign/system_config/installation/" ;;
    kyverno:Darwin)    echo "brew install kyverno  | https://kyverno.io/docs/kyverno-cli/install/" ;;
    promtool:Darwin)   echo "brew install prometheus  | https://prometheus.io/download/ (promtool is in the archive)" ;;
    promtool:*)        echo "https://github.com/prometheus/prometheus/releases (prometheus-<version>.linux-amd64.tar.gz: promtool) | https://prometheus.io/download/" ;;
    kyverno:*)         echo "https://github.com/kyverno/kyverno/releases (kyverno-cli_v<version>_linux_x86_64.tar.gz) | https://kyverno.io/docs/kyverno-cli/install/" ;;
    kubeconform:Darwin) echo "brew install kubeconform  | https://github.com/yannh/kubeconform#installation" ;;
    kubeconform:*)     echo "https://github.com/yannh/kubeconform/releases (kubeconform-linux-<arch>.tar.gz: amd64 or arm64)" ;;
    helm:Darwin)       echo "brew install helm  | https://helm.sh/docs/intro/install/" ;;
    helm:*)            echo "https://helm.sh/docs/intro/install/ (the release archive or the install script)" ;;
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
# A tool that is on PATH but cannot even print its version (a broken install) counts as missing.
# An empty <min> only skips the version comparison.
check() {
  local tool="$1" min="$2" cmd="$3" out ver
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing "$tool" "$(hint "$tool")"
    return
  fi
  if ! out="$(eval "$cmd" 2>/dev/null)"; then
    missing "$tool" "found, but '$cmd' failed - reinstall: $(hint "$tool")"
    return
  fi
  ver="$(printf '%s\n' "$out" | first_version || true)"
  if [ -n "$min" ] && [ -n "$ver" ] && ! version_ge "$ver" "$min"; then
    too_old "$tool" "$ver" "$min"
    return
  fi
  ok "$tool" "${ver:-installed}"
}

# The tool list: name, minimum version ("" = any), and the command that prints the version.
echo "SafeOps lab tools ($OS)"
echo ""
check git        ""               "git --version"
check gh         ""               "gh --version"        # required even when the fork is cloned over SSH
check make       ""               "make --version"
check docker     ""               "docker --version"
check terraform  "$MIN_TERRAFORM" "terraform version"
check kind       "$MIN_KIND"      "kind version"
check kubectl    "$MIN_KUBECTL"   "kubectl version --client"
check flux       "$MIN_FLUX"      "flux version --client"
check sops       ""               "sops --version"
check age-keygen ""               "age-keygen --version"
check pre-commit ""               "pre-commit --version"
# An unreadable pin would make the minimum "any version": report it instead.
pin_re='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
if [[ "$MIN_CHECKOV" =~ $pin_re ]]; then
  check checkov  "$MIN_CHECKOV"   "checkov --version"   # the terraform-security pre-commit hook fails without it, or with an older one
else
  missing checkov "cannot read the Checkov pin (one 'checkov==X.Y.Z') from .github/workflows/pre-commit.yml"
fi
check jq         ""               "jq --version"        # the AI agent's kube-context hook (Chapter 01) and scripts/lab-pod.sh
check yq         "4"              "yq --version"        # the pre-commit guardrails that read the Flux manifests (Chapter 03 on)
check kyverno    "$MIN_KYVERNO"   "kyverno version"     # the admission policy tests in pre-commit (Chapter 16)
check cosign     "$MIN_COSIGN"    "cosign version"      # verify image signatures and SBOMs (Chapter 17)
check promtool   "$MIN_PROMTOOL"  "promtool --version"  # the platform alert tests in pre-commit
check helm       "$MIN_HELM"      "helm version --short"  # the tool-versions test in pre-commit (Chapter 20)
check kubeconform ""              "kubeconform -v"      # manifests against the next Kubernetes version (Chapter 20)

# docker buildx is a Docker CLI plugin, not a command on PATH, so `check` cannot find it.
# Chapter 10 compares image digests in the registry with `docker buildx imagetools inspect`.
if command -v docker >/dev/null 2>&1; then
  if out="$(docker buildx version 2>/dev/null)"; then
    ok "docker buildx" "$(printf '%s\n' "$out" | first_version || echo installed)"
  else
    missing "docker buildx" "$(hint buildx)"
  fi
fi

# Docker must not only be installed but running - the kind nodes are containers.
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker daemon" "running"
    cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
    mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    # Anything that is not a plain number (an error text, an empty answer) counts as 0.
    case "$cpus" in ''|*[!0-9]*) cpus=0 ;; esac
    case "$mem_bytes" in ''|*[!0-9]*) mem_bytes=0 ;; esac
    mem_gib="$(awk -v b="$mem_bytes" 'BEGIN { printf "%.1f", b / 1024 / 1024 / 1024 }')"
    if [ "$cpus" -lt "$MIN_DOCKER_CPUS" ]; then
      too_low "docker cpus" "$cpus" "$MIN_DOCKER_CPUS - raise it in Docker Desktop / OrbStack / Colima settings"
    else
      ok "docker cpus" "$cpus"
    fi
    # bash compares only whole numbers, so awk compares the GiB values (with decimals).
    if awk -v m="$mem_gib" -v min="$MIN_DOCKER_MEM_GIB" 'BEGIN { exit !(m < min) }'; then
      too_low "docker memory" "${mem_gib} GiB" "8 GB - raise it in Docker Desktop / OrbStack / Colima settings"
    elif awk -v m="$mem_gib" -v rec="$REC_DOCKER_MEM_GIB" 'BEGIN { exit !(m < rec) }'; then
      ok "docker memory" "${mem_gib} GiB (enough; ${REC_DOCKER_MEM_GIB} GB recommended for the later labs)"
    else
      ok "docker memory" "${mem_gib} GiB"
    fi
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
