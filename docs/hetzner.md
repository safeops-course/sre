# Hetzner (hcloud) MVP Runbook

This runbook is the authoritative path for provisioning and validating the Hetzner cluster used in this repo.

## MVP Decisions (As Of 2026-02-16)

- Runtime: `kube-hetzner` (k3s) via Terraform.
- Topology: `1x cx23` control-plane + `1x cx23` worker.
- Environments: `develop`, `staging`, `production` namespaces in one cluster.
- GitOps: Flux with sync path `./flux/bootstrap/flux-system`.
- Flux Git auth model (MVP): **public GitHub repo over HTTPS** (no Git token required by default).
- Demo ingress strategy (MVP): HTTP + Host header (`backend.local`, `frontend.local`) against LB IP.

## Required GitHub Actions Secrets

Set these in: GitHub -> Settings -> Secrets and variables -> Actions.

Required:
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `HCLOUD_TOKEN`
- `HCLOUD_SSH_PUBLIC_KEY`
- `HCLOUD_SSH_PRIVATE_KEY`

Optional (only when needed):
- `SOPS_AGE_KEY`: needed when using encrypted manifests under `flux/secrets/**`.
- `GHCR_USERNAME` / `GHCR_TOKEN`: needed when GHCR images are private.
- `FLUX_GIT_TOKEN`: not required for the default public-repo MVP path.
- `BACKUP_S3_ACCESS_KEY_ID` / `BACKUP_S3_SECRET_ACCESS_KEY` / `BACKUP_S3_BUCKET`: needed when creating CNPG backup object-store secret via Terraform.
- `BACKUP_S3_ENDPOINT` / `BACKUP_S3_REGION`: optional, for AWS-compatible providers (for example R2/S3 endpoint tuning).

## Preflight Checklist

1. Confirm repo owner/repo references are correct for your fork/org:
   - `scripts/configure-repo.sh --github-owner <owner> --github-repo <repo>`
2. Confirm `infra/terraform/hcloud_cluster/main.tf` validates with your module version.
3. Confirm GitHub Environment `hcloud` exists and has manual approval policy.
4. Confirm Hetzner project has required MicroOS snapshots for `kube-hetzner`.

## Provisioning Workflow

### 1. Plan on PR

Trigger `Terraform - Plan (Hetzner)` by opening a PR with changes in:
- `infra/terraform/hcloud_cluster/**`
- `flux/**`

Required outcome:
- workflow completes successfully
- no unexpected resource drift in plan output

### 2. Apply Manually

Run `Terraform - Apply (Hetzner)` via `workflow_dispatch` with:
- `action=apply`

Required outcome:
- workflow succeeds
- no failed Terraform steps

## Post-Apply Verification

Use a workstation with `kubectl` and Terraform backend credentials (R2) to read current state and verify cluster health.

1. Export required env vars:
```bash
export AWS_ACCESS_KEY_ID="<R2_ACCESS_KEY_ID>"
export AWS_SECRET_ACCESS_KEY="<R2_SECRET_ACCESS_KEY>"
```

2. Fetch kubeconfig from Terraform state:
```bash
cd infra/terraform/hcloud_cluster
terraform init -input=false
terraform output --raw kubeconfig > kubeconfig.yaml
export KUBECONFIG="$(pwd)/kubeconfig.yaml"
kubectl get nodes
```

3. Verify namespaces:
```bash
kubectl get ns | rg "flux-system|develop|staging|production|observability"
```

4. Verify Flux controllers and sync:
```bash
kubectl -n flux-system get pods
kubectl -n flux-system get gitrepositories.source.toolkit.fluxcd.io
kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io
```

Expected kustomizations include:
- `flux-system`
- `apps-develop`
- `apps-staging`
- `apps-production`
- `infrastructure`

5. Verify app rollout per namespace:
```bash
kubectl -n develop get deploy,svc,ing
kubectl -n staging get deploy,svc,ing
kubectl -n production get deploy,svc,ing
```

## Ingress Verification (MVP)

1. Discover ingress LB IP:
```bash
kubectl get svc -A | rg LoadBalancer
```

2. Test frontend and backend with Host headers:
```bash
LB_IP="<load-balancer-ip>"
curl -H "Host: frontend.local" "http://${LB_IP}/" -I
curl -H "Host: backend.local" "http://${LB_IP}/healthz" -i
```

Optional `/etc/hosts` for browser testing:
```text
<LB_IP> frontend.local
<LB_IP> backend.local
```

## DNS/TLS Strategy (Short-Term MVP)

- DNS: local hosts file or test DNS entries pointing to LB IP.
- TLS: intentionally deferred for MVP to keep bootstrap deterministic.
- When moving beyond MVP: add managed DNS records + cert-manager and switch ingresses to HTTPS.

## Private Repo Variant (Non-MVP)

If the repo is private:
- set `FLUX_GIT_TOKEN`
- configure Flux `GitRepository` auth via secret-backed HTTPS credentials
- re-validate `flux-system` source readiness after reconciliation

Keep this as a deliberate opt-in path; default training path remains public HTTPS.
