# GitOps Workflow and Deployment Process

## Overview

As of February 16, 2026, the active deployment model is:

- **Develop** namespace auto-updated from env-tagged `develop-*` images.
- **Staging** namespace auto-updated from env-tagged `staging-*` images.
- **Production** namespace auto-updated from env-tagged `production-*` images created by manual promotion workflows.

Flux sync source:
- Git repository branch: `main`
- Path: `./flux/bootstrap/flux-system`

## Actual Image Tagging Strategy

Backend and frontend build workflows publish multiple tags per build:

- Environment alias: `develop` or `staging`
- Immutable env/version tag: `<env>-v<major>.<minor>.<patch>-<short_sha>-<unix_ts>`
- Commit tag: `<short_sha>`

Examples:
- `develop-v0.0.1-a1b2c3d-1738860000`
- `staging-v0.0.1-a1b2c3d-1738860123`
- `production-v0.0.1-a1b2c3d-1738861000` (from promotion workflow)

Production promotion workflows also maintain alias tag `production`.

## CI/CD to Flux Flow

### 1. Build (develop branch)
- Trigger: push to `develop` in service repos (`backend` or `frontend`).
- Workflow builds and pushes `develop-*` tags to GHCR.
- Flux `ImagePolicy` in namespace `develop` selects latest matching tag by extracted timestamp.
- Flux `ImageUpdateAutomation` commits setter updates into this repo (`main`).
- Flux applies the new image tag to `develop`.

### 2. Build (main branch)
- Trigger: push to `main` in service repos.
- Workflow builds and pushes `staging-*` tags to GHCR.
- Flux `ImagePolicy` in namespace `staging` selects latest matching tag.
- Flux writes the updated tag to Git and reconciles `staging`.

### 3. Promotion to production
- Trigger: manual `workflow_dispatch` in service repo (`promote-production.yml`).
- Workflow chooses a `staging-*` tag (explicit input or latest), then retags to:
  - `production`
  - `production-v<major>.<minor>.<patch>-<short_sha>-<unix_ts>`
- Flux `ImagePolicy` in namespace `production` matches `production-*` and deploys automatically.
- The promotion workflow also creates/publishes GitHub Release metadata and bumps next version tag.

## Flux Objects Used (Current State)

The active implementation uses Flux Image Automation (Git write-back), not ResourceSet runtime mutation.

- `ImageRepository` objects in `flux-system`:
  - `flux/bootstrap/infrastructure/image-automation/backend-image-repo.yaml`
  - `flux/bootstrap/infrastructure/image-automation/frontend-image-repo.yaml`
- `ImagePolicy` objects per env:
  - backend: `flux/apps/backend/develop|staging|production/image-policy.yaml`
  - frontend: `flux/apps/frontend/overlays/develop|staging|production/image-policy.yaml`
- `ImageUpdateAutomation` objects per env:
  - backend: `flux/apps/backend/develop|staging|production/image-automation.yaml`
  - frontend: `flux/apps/frontend/overlays/develop|staging|production/image-automation.yaml`
- `GitRepository` source for write-back:
  - `flux/bootstrap/infrastructure/image-automation/git-repository.yaml`

Note: ResourceSet examples are currently commented out in `flux/bootstrap/apps/*`.

## Regex Policies in Use

Backend and frontend use the same tag filters per environment:

- develop: `^develop-v[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]+-(?P<ts>[0-9]+)$`
- staging: `^staging-v[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]+-(?P<ts>[0-9]+)$`
- production: `^production-v[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]+-(?P<ts>[0-9]+)$`

Policies extract `ts` and choose the latest numerically.

## Deployment Verification

```bash
# Flux status
flux get kustomizations -n flux-system
flux get images all -A

# Check deployed image tags
kubectl -n develop get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n staging get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n production get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

## Rollback Paths

Preferred rollback is GitOps-first:

1. Revert the Flux bot commit in this repository (`main`) that bumped the image tag.
2. Let Flux reconcile the reverted manifest.

Emergency rollback can use `kubectl rollout undo`, but that may drift from Git and should be reconciled back via Git immediately after.

## Troubleshooting

```bash
# Reconcile source and kustomizations
flux reconcile source git flux-system
flux reconcile kustomization apps-develop -n flux-system
flux reconcile kustomization apps-staging -n flux-system
flux reconcile kustomization apps-production -n flux-system

# Inspect image automation
kubectl get imagerepository -n flux-system
kubectl get imagepolicy -A
kubectl get imageupdateautomation -A

# Check controller logs
kubectl logs -n flux-system deploy/image-reflector-controller --tail=100
kubectl logs -n flux-system deploy/image-automation-controller --tail=100
```

## Security Notes

1. Use least-privilege credentials for Flux Git and registry access.
2. Keep network isolation between `develop`, `staging`, and `production`.
3. Keep auditability: all image changes should be traceable through Git commits and workflow runs.

## Additional Resources

- [Flux Documentation](https://fluxcd.io/flux/)
- [FluxCD Image Automation](https://fluxcd.io/flux/guides/image-update/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Kustomize Documentation](https://kubectl.docs.kubernetes.io/references/kustomize/)
