# Flux GitOps Configuration

This directory contains Flux GitOps manifests for the SRE infrastructure.

## Directory Structure

```
flux/
├── apps/                    # Application deployments
├── bootstrap/               # Cluster bootstrap (namespaces, kustomizations, infra wiring)
├── infrastructure/          # Infrastructure components (monitoring, ingress, etc.)
└── secrets/                 # SOPS-encrypted secrets (examples/templates)
```

## Flux Reconciliation

The Flux controllers bootstrapped by Terraform reconcile from:
- **Repository:** configured via Terraform (`TF_VAR_flux_git_repository_url`, typically `https://github.com/<owner>/<repo>.git`)
- **Branch:** `main`
- **Path:** `./flux/bootstrap/flux-system`

## How it works

1. Flux monitors this repository for changes
2. When changes are detected, Flux applies them to the cluster
3. All changes are declarative and version-controlled

## Adding new applications

1. Create manifests in `flux/apps/<app-name>/`
2. Wire it in via a Kustomization under `flux/bootstrap/apps/<environment>/`
3. Commit and push changes
4. Flux will automatically deploy the application

## Monitoring

```bash
# Check Flux status
flux check

# View all Flux sources
flux get sources all

# View all Flux kustomizations
flux get kustomizations

# Reconcile immediately (force sync)
flux reconcile source git flux-system
flux reconcile kustomization flux-system
```
