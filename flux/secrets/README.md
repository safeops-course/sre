# Secrets Management with SOPS and age

This directory contains encrypted Kubernetes secrets managed with [Mozilla SOPS](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age) encryption.

## Overview

Flux has native support for decrypting SOPS-encrypted secrets during deployment. This allows you to:

- ✅ Store encrypted secrets safely in Git
- ✅ Use GitOps workflows for secret management
- ✅ Audit secret changes via Git history
- ✅ No external secret management service required
- ✅ Simple age key-based encryption

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Developer Workflow                        │
│                                                              │
│  1. Create secret     2. Encrypt with    3. Commit to Git  │
│     (plaintext)          SOPS + age         (encrypted)     │
│                                                              │
│  kubectl create secret → sops -e → git commit               │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          │ Git Push
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    Flux Reconciliation                       │
│                                                              │
│  1. Detect changes    2. Decrypt with    3. Apply to K8s   │
│     in Git repo          age private key    cluster         │
│                                                              │
│  GitRepository → Kustomization (decryption) → Secret        │
│                       (via age key in                        │
│                        sops-age secret)                      │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

Install required tools:

```bash
# Install age (encryption tool)
brew install age  # macOS
# or
apt install age   # Debian/Ubuntu

# Install SOPS (encryption tool)
brew install sops  # macOS
# or
wget https://github.com/getsops/sops/releases/download/v3.9.3/sops-v3.9.3.linux.amd64 \
  -O /usr/local/bin/sops && chmod +x /usr/local/bin/sops
```

## Initial Setup

### 1. Generate age Key Pair (ALREADY DONE)

The repository already has an age key configured in `.sops.yaml`. The public key is:

```
age160c2nksz88e50qtaywm0qu3x4ms9lxzyt4ym9tv8n803fl979gdsruuy0s
```

**⚠️ For new environments or production use, generate a new key pair:**

```bash
# Generate new age key pair
age-keygen -o age.agekey

# Output will show:
# Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# (save this in .sops.yaml)

# The private key is saved in age.agekey
# ⚠️ KEEP THIS PRIVATE! DO NOT COMMIT TO GIT!
```

### 2. Store age Private Key in Flux

The private key must be stored as a Kubernetes Secret for Flux to decrypt secrets:

```bash
# Create sops-age secret in flux-system namespace
cat age.agekey | kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin

# Verify
kubectl get secret sops-age -n flux-system
```

**⚠️ Alternative for Terraform-managed clusters:**

Add to `infra/terraform/kind_cluster/main.tf`:

```hcl
resource "kubernetes_secret" "sops_age" {
  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  data = {
    "age.agekey" = file("${path.module}/age.agekey")
  }
}
```

### 3. Configure Kustomization to Decrypt Secrets

Each Flux Kustomization must reference the `sops-age` secret:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: backend-develop
  namespace: flux-system
spec:
  interval: 10m
  path: ./flux/secrets/develop
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

## Usage

### Creating Encrypted Secrets

#### Method 1: Encrypt Existing Secret

```bash
# Create a plain Kubernetes Secret YAML
kubectl create secret generic backend-secrets \
  --from-literal=api-key="my-secret-api-key" \
  --from-literal=jwt-secret="change-me" \
  --dry-run=client -o yaml > flux/secrets/develop/backend-secrets.yaml

# Encrypt with SOPS
sops --encrypt --in-place flux/secrets/develop/backend-secrets.yaml

# Commit encrypted file
git add flux/secrets/develop/backend-secrets.yaml
git commit -m "Add encrypted backend secrets for develop"
git push
```

#### Method 2: Create and Encrypt in One Step

```bash
# Create encrypted secret directly
sops --encrypt --encrypted-regex '^(data|stringData)$' \
  --age age160c2nksz88e50qtaywm0qu3x4ms9lxzyt4ym9tv8n803fl979gdsruuy0s \
  flux/secrets/develop/backend-secrets.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: backend-secrets
  namespace: develop
type: Opaque
stringData:
  api-key: "my-secret-api-key"
  jwt-secret: "change-me"
EOF
```

### Viewing Encrypted Secrets

```bash
# View encrypted file (shows encrypted data)
cat flux/secrets/develop/backend-secrets.yaml

# Decrypt and view (requires age private key)
sops --decrypt flux/secrets/develop/backend-secrets.yaml

# Edit encrypted secret (decrypts, opens editor, re-encrypts on save)
sops flux/secrets/develop/backend-secrets.yaml
```

### Updating Encrypted Secrets

```bash
# Edit with SOPS (automatically decrypts/encrypts)
sops flux/secrets/develop/backend-secrets.yaml

# Make changes in your editor, save and quit
# SOPS will automatically re-encrypt the file

# Commit changes
git add flux/secrets/develop/backend-secrets.yaml
git commit -m "Update backend secrets"
git push
```

### Using Secrets in Deployments

Reference the encrypted secret in your Deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  template:
    spec:
      containers:
        - name: backend
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: app-postgres-app
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-postgres-app
                  key: password
            - name: DATABASE_URL
              value: "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@app-postgres-rw:5432/app?sslmode=disable"
            - name: API_KEY
              valueFrom:
                secretKeyRef:
                  name: backend-secrets
                  key: api-key
```

## Directory Structure

```
flux/secrets/
├── README.md (this file)
├── develop/
│   ├── kustomization.yaml
│   └── backend-secrets.yaml (encrypted)
├── staging/
│   ├── kustomization.yaml
│   └── backend-secrets.yaml (encrypted)
└── production/
    ├── kustomization.yaml
    └── backend-secrets.yaml (encrypted)
```

## Example Encrypted Secret

After encryption, a secret looks like this:

```yaml
apiVersion: v1
kind: Secret
metadata:
    name: backend-secrets
    namespace: develop
type: Opaque
data:
    api-key: ENC[AES256_GCM,data:xxxxx,iv:xxxxx,tag:xxxxx,type:str]
    jwt-secret: ENC[AES256_GCM,data:xxxxx,iv:xxxxx,tag:xxxxx,type:str]
sops:
    kms: []
    gcp_kms: []
    azure_kv: []
    hc_vault: []
    age:
        - recipient: age160c2nksz88e50qtaywm0qu3x4ms9lxzyt4ym9tv8n803fl979gdsruuy0s
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
            -----END AGE ENCRYPTED FILE-----
    lastmodified: "2025-01-08T12:00:00Z"
    mac: ENC[AES256_GCM,data:xxxxx,iv:xxxxx,tag:xxxxx,type:str]
    pgp: []
    encrypted_regex: ^(data|stringData)$
    version: 3.9.3
```

## Security Best Practices

### ✅ DO:

- ✅ Keep age private key (`age.agekey`) secure and backed up
- ✅ Use different age keys for different environments (dev/staging/prod)
- ✅ Rotate age keys periodically (re-encrypt all secrets with new key)
- ✅ Use `encrypted_regex: ^(data|stringData)$` to encrypt only secret values
- ✅ Commit encrypted secrets to Git
- ✅ Review secret changes in Git diffs (metadata is visible)
- ✅ Use separate namespaces for environment isolation

### ❌ DON'T:

- ❌ Commit age private key to Git
- ❌ Share age private key via insecure channels (email, Slack)
- ❌ Use the same age key for all environments
- ❌ Encrypt the entire YAML file (use `encrypted_regex`)
- ❌ Store plaintext secrets in Git
- ❌ Forget to backup age private key (lost key = lost secrets!)

## Troubleshooting

### Secret not appearing in cluster

1. Check Kustomization status:
```bash
kubectl get kustomization -n flux-system
```

2. Check if sops-age secret exists:
```bash
kubectl get secret sops-age -n flux-system
```

3. Check Flux logs:
```bash
kubectl logs -n flux-system deployment/kustomize-controller
```

### SOPS decryption failed

Error: `failed to decrypt secret: no age private key found`

**Solution:** Ensure `sops-age` secret exists in `flux-system` namespace:

```bash
cat age.agekey | kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin
```

### Wrong age key used

Error: `sops metadata section not found`

**Solution:** The secret was encrypted with a different age public key. Re-encrypt with correct key:

```bash
# Decrypt with old key
sops --decrypt secret.yaml > secret-plain.yaml

# Re-encrypt with new key
sops --encrypt --age age1NEW_PUBLIC_KEY secret-plain.yaml > secret.yaml

# Remove plaintext file
rm secret-plain.yaml
```

## Key Rotation

To rotate age keys:

1. **Generate new age key:**
```bash
age-keygen -o age-new.agekey
```

2. **Update `.sops.yaml` with new public key**

3. **Re-encrypt all secrets:**
```bash
# For each encrypted secret file
sops rotate --in-place flux/secrets/develop/backend-secrets.yaml
```

4. **Update sops-age secret in cluster:**
```bash
kubectl delete secret sops-age -n flux-system
cat age-new.agekey | kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin
```

5. **Backup old key (for disaster recovery)**

## Resources

- [Flux SOPS Guide](https://fluxcd.io/flux/guides/mozilla-sops/)
- [SOPS Documentation](https://github.com/getsops/sops)
- [age Documentation](https://github.com/FiloSottile/age)
- [Flux Kustomization Decryption](https://fluxcd.io/flux/components/kustomize/kustomizations/#decryption)
