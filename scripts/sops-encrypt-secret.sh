#!/bin/bash
set -euo pipefail

# Helper script to create and encrypt secrets with SOPS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    cat <<EOF
Usage: $0 ENVIRONMENT SECRET_NAME [NAMESPACE]

Create and encrypt a Kubernetes Secret with SOPS

ARGUMENTS:
    ENVIRONMENT     Target directory under flux/secrets/: develop, staging,
                    production, or local (the kind profile - encrypted with
                    your own key, see scripts/sops-setup.sh --local)
    SECRET_NAME     Name of the secret (e.g., backend-secrets)
    NAMESPACE       Namespace the Secret is created in (default: ENVIRONMENT,
                    or develop when ENVIRONMENT is local)

EXAMPLES:
    # Create encrypted secret for develop environment
    $0 develop backend-secrets

    # Create encrypted secret for production
    $0 production backend-secrets
    # Local kind profile: encrypted with your key, applied to develop
    $0 local lab-secret

WORKFLOW:
    1. Creates a plaintext secret template
    2. Opens it in \$EDITOR (or vi)
    3. After you save and quit, encrypts it with SOPS
    4. Saves encrypted version to flux/secrets/ENVIRONMENT/

NOTE:
    - Make sure .sops.yaml is configured with age public key
    - Make sure SOPS and age are installed
    - The plaintext file is automatically deleted after encryption

EOF
}

create_and_encrypt() {
    local env="$1"
    local secret_name="$2"
    local namespace="${3:-$env}"
    [[ "${env}" == "local" && -z "${3:-}" ]] && namespace="develop"
    local secrets_dir="${REPO_ROOT}/flux/secrets/${env}"
    local output_file="${secrets_dir}/${secret_name}.yaml"
    local temp_file="${secrets_dir}/${secret_name}.yaml.tmp"

    # Validate environment
    if [[ ! -d "${secrets_dir}" ]]; then
        echo "❌ Invalid environment: ${env}"
        echo "   Available: develop, staging, production, local"
        exit 1
    fi

    # Check if secret already exists
    if [[ -f "${output_file}" ]]; then
        echo "⚠️  Secret already exists: ${output_file}"
        read -p "   Edit existing secret with SOPS? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sops "${output_file}"
            echo "✅ Secret updated"
            exit 0
        else
            exit 1
        fi
    fi

    # Create template
    cat > "${temp_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${namespace}
type: Opaque
stringData:
  # Add your secret keys here
  # Example:
  # database-url: "postgresql://user:pass@host:5432/db"
  # api-key: "your-api-key"
  # jwt-secret: "your-jwt-secret"

  # TODO: Replace with actual secret values
  example-key: "example-value"
EOF

    echo "📝 Created template: ${temp_file}"
    echo "   Opening in editor..."
    echo

    # Open in editor
    ${EDITOR:-vi} "${temp_file}"

    echo
    read -p "Encrypt this secret? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Cancelled"
        rm "${temp_file}"
        exit 1
    fi

    # Encrypt with SOPS
    echo "🔐 Encrypting secret..."
    sops --encrypt "${temp_file}" > "${output_file}"

    # Remove temp file
    rm "${temp_file}"

    echo "✅ Encrypted secret created: ${output_file}"
    echo
    echo "Next steps:"
    echo "  1. Add to kustomization: edit ${secrets_dir}/kustomization.yaml"
    echo "  2. Uncomment: # - ${secret_name}.yaml"
    echo "  3. Commit: git add ${output_file} && git commit -m 'Add ${secret_name} for ${env}'"
    echo "  4. Push: git push"
}

# Main
if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage
    exit 1
fi

ENV="$1"
SECRET_NAME="$2"
NAMESPACE_ARG="${3:-}"

# Check tools
if ! command -v sops &> /dev/null; then
    echo "❌ sops is not installed"
    echo "   Install: brew install sops"
    exit 1
fi

create_and_encrypt "${ENV}" "${SECRET_NAME}" "${NAMESPACE_ARG}"
