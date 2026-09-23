#!/bin/bash
set -euo pipefail

# SOPS + age setup script for Flux
# This script helps with initial SOPS configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AGE_KEY_FILE="${REPO_ROOT}/age.agekey"

echo "🔐 SOPS + age Setup for Flux"
echo "============================"
echo

# Check if tools are installed
check_tools() {
    echo "📋 Checking required tools..."

    if ! command -v age &> /dev/null; then
        echo "❌ age is not installed"
        echo "   Install: brew install age (macOS) or apt install age (Linux)"
        exit 1
    fi

    if ! command -v sops &> /dev/null; then
        echo "❌ sops is not installed"
        echo "   Install: brew install sops (macOS) or see https://github.com/getsops/sops"
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        echo "❌ kubectl is not installed"
        exit 1
    fi

    echo "✅ All tools are installed"
    echo
}

# Generate age key if it doesn't exist
generate_age_key() {
    if [[ -f "${AGE_KEY_FILE}" ]]; then
        echo "⚠️  age key already exists at: ${AGE_KEY_FILE}"
        echo "   Public key:"
        grep "# public key:" "${AGE_KEY_FILE}" | cut -d: -f2 | tr -d ' '
        echo
        read -p "   Generate new key? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
        mv "${AGE_KEY_FILE}" "${AGE_KEY_FILE}.$(date +%Y%m%d-%H%M%S).bak"
        echo "   Backed up old key"
    fi

    echo "🔑 Generating new age key pair..."
    age-keygen -o "${AGE_KEY_FILE}"

    PUBLIC_KEY=$(grep "# public key:" "${AGE_KEY_FILE}" | cut -d: -f2 | tr -d ' ')

    echo
    echo "✅ Age key generated!"
    echo "   Private key: ${AGE_KEY_FILE}"
    echo "   Public key:  ${PUBLIC_KEY}"
    echo
    echo "⚠️  IMPORTANT:"
    echo "   1. Backup ${AGE_KEY_FILE} securely (DO NOT COMMIT TO GIT!)"
    echo "   2. Update .sops.yaml with the public key"
    echo "   3. Create sops-age secret in Kubernetes (see below)"
    echo
}

# Create sops-age secret in Kubernetes
create_k8s_secret() {
    if [[ ! -f "${AGE_KEY_FILE}" ]]; then
        echo "❌ Age key not found at: ${AGE_KEY_FILE}"
        echo "   Run with --generate first"
        exit 1
    fi

    echo "📦 Creating sops-age secret in Kubernetes..."
    echo

    # Check if kubectl is connected
    if ! kubectl cluster-info &> /dev/null; then
        echo "❌ kubectl is not connected to a cluster"
        echo "   Make sure your cluster is running and kubeconfig is configured"
        exit 1
    fi

    # Check if flux-system namespace exists
    if ! kubectl get namespace flux-system &> /dev/null; then
        echo "❌ flux-system namespace not found"
        echo "   Make sure Flux is installed in your cluster"
        exit 1
    fi

    # Check if secret already exists
    if kubectl get secret sops-age -n flux-system &> /dev/null; then
        echo "⚠️  sops-age secret already exists in flux-system namespace"
        read -p "   Replace it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl delete secret sops-age -n flux-system
        else
            echo "   Skipping secret creation"
            return
        fi
    fi

    # Create secret
    cat "${AGE_KEY_FILE}" | kubectl create secret generic sops-age \
        --namespace=flux-system \
        --from-file=age.agekey=/dev/stdin

    echo "✅ sops-age secret created in flux-system namespace"
    echo
}

# Update .sops.yaml with public key
update_sops_config() {
    if [[ ! -f "${AGE_KEY_FILE}" ]]; then
        echo "❌ Age key not found at: ${AGE_KEY_FILE}"
        exit 1
    fi

    PUBLIC_KEY=$(grep "# public key:" "${AGE_KEY_FILE}" | cut -d: -f2 | tr -d ' ')
    SOPS_CONFIG="${REPO_ROOT}/.sops.yaml"

    echo "📝 Update .sops.yaml with public key:"
    echo "   ${PUBLIC_KEY}"
    echo
    echo "   Replace all 'age:' lines in ${SOPS_CONFIG} with:"
    echo "   age: ${PUBLIC_KEY}"
    echo
}

# Register the local key in .sops.yaml (local profile rule only).
# The platform rules keep the SafeOps key; learners only ever encrypt under
# flux/secrets/local/, which is what the local Flux profile decrypts.
update_local_sops_rule() {
    if [[ ! -f "${AGE_KEY_FILE}" ]]; then
        echo "❌ Age key not found at: ${AGE_KEY_FILE}"
        exit 1
    fi
    PUBLIC_KEY=$(grep "# public key:" "${AGE_KEY_FILE}" | cut -d: -f2 | tr -d ' ')
    SOPS_CONFIG="${REPO_ROOT}/.sops.yaml"

    if ! grep -q "path_regex: flux/secrets/local/" "${SOPS_CONFIG}"; then
        echo "❌ No flux/secrets/local rule in ${SOPS_CONFIG}"
        exit 1
    fi
    # Replace only the recipient on the line that follows the local path rule.
    awk -v key="${PUBLIC_KEY}" '
        /path_regex: flux\/secrets\/local\// { in_local = 1 }
        in_local && /^[[:space:]]*age: / { sub(/age: .*/, "age: " key); in_local = 0 }
        { print }
    ' "${SOPS_CONFIG}" > "${SOPS_CONFIG}.tmp" && mv "${SOPS_CONFIG}.tmp" "${SOPS_CONFIG}"

    echo "✅ .sops.yaml: flux/secrets/local/** now encrypts to ${PUBLIC_KEY}"
    echo "   Commit .sops.yaml in your fork; keep ${AGE_KEY_FILE} out of Git."
    echo
}

# Show usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Setup SOPS + age encryption for Flux GitOps

OPTIONS:
    --generate          Generate new age key pair
    --create-secret     Create sops-age secret in Kubernetes
    --update-config     Show instructions for updating .sops.yaml
    --all               Run all steps (generate, create secret, show config)
    --local             Local (kind) profile: generate key if missing, register
                        its public half for flux/secrets/local/ in .sops.yaml,
                        and create/refresh the sops-age secret in the cluster
    -h, --help          Show this help message

EXAMPLES:
    # Initial setup (all steps)
    $0 --all

    # Just generate age key
    $0 --generate

    # Create Kubernetes secret (after generating key)
    $0 --create-secret

EOF
}

# Main
main() {
    case "${1:-}" in
        --generate)
            check_tools
            generate_age_key
            update_sops_config
            ;;
        --create-secret)
            check_tools
            create_k8s_secret
            ;;
        --update-config)
            update_sops_config
            ;;
        --all)
            check_tools
            generate_age_key
            create_k8s_secret
            update_sops_config
            ;;
        --local)
            check_tools
            if [[ ! -f "${AGE_KEY_FILE}" ]]; then
                generate_age_key
            else
                echo "🔑 Using existing key: ${AGE_KEY_FILE}"
            fi
            update_local_sops_rule
            # infra/terraform/kind_cluster already created sops-age from this
            # key file; only create it when it is missing (no prompts - this
            # runs inside course labs and CI).
            if kubectl -n flux-system get secret sops-age &> /dev/null; then
                echo "✅ sops-age secret already present in flux-system (created by Terraform)"
            else
                create_k8s_secret
            fi
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
