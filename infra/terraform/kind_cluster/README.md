# Kind Cluster with Flux Operator

This Terraform configuration creates a local Kubernetes cluster using [kind](https://kind.sigs.k8s.io/) and installs the [Flux Operator](https://fluxcd.control-plane.io/operator/) for GitOps continuous delivery.

## Architecture

- **Kind Cluster**: 1 control-plane node + 2 worker nodes
- **Flux Operator**: Installed via Helm chart
- **FluxInstance**: Deploys all Flux controllers (source, kustomize, helm, notification, image-reflector, image-automation)
- **Optional GitOps Bootstrap**: Automatically connects to your Git repository

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Quick Start

### 1. Initialize Terraform

```bash
cd infra/terraform/kind_cluster
terraform init
```

### 2. Create the Cluster

```bash
terraform apply
```

This will:
1. Create a kind cluster named `sre-control-plane` (+ Traefik, metrics-server)
2. Install the Flux Operator
3. Deploy a FluxInstance with all Flux controllers, syncing `./flux/bootstrap/profiles/local` from the course repo
4. Generate the local runtime secrets (JWT, Postgres owner, MinIO, sops-age from `age.agekey`) - see `local-profile.tf`
5. Merge the kubeconfig into your `~/.kube/config`

Defaults target the SafeOps course repo and the local profile; set `TF_VAR_flux_git_repository_url` to your fork and `TF_VAR_flux_kustomization_path=./flux/bootstrap/flux-system` for the full platform (`docs/local-dev.md`).

### 3. Verify Installation

```bash
# Check cluster
kubectl cluster-info --context kind-sre-control-plane

# Check Flux Operator
kubectl -n flux-system get pods

# Check FluxInstance
kubectl -n flux-system get fluxinstance
```

## GitOps Bootstrap (Optional)

### Step 1: Create GitHub App

Follow the guide in [docs/github-app-setup.md](../../../docs/github-app-setup.md) to:
1. Create a GitHub App at https://github.com/settings/apps
2. Install it on your repository
3. Download the private key PEM file

### Step 2: Configure Terraform Variables

Create a `terraform.tfvars` file with your GitHub App credentials:

```hcl
# GitHub App Configuration
github_app_id              = "123456"
github_app_installation_id = "12345678"
github_app_private_key_file = "~/.ssh/flux-github-app.pem"

# GitOps Configuration (already set)
flux_git_repository_url    = "https://github.com/safeops-course/sre.git"
flux_git_repository_branch = "main"
flux_kustomization_path    = "./flux/bootstrap/flux-system"
```

The Kubernetes secret will be created automatically by Terraform.

### Step 3: Apply Terraform

```bash
terraform apply
```

This will create a FluxInstance with built-in sync configured to:
- Monitor the `safeops-course/sre` repository
- Sync from `./flux/bootstrap/flux-system` path
- Use GitHub App authentication

## Configuration Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `flux_git_repository_url` | Git repository URL to sync with Flux | `""` (disabled) |
| `flux_git_repository_branch` | Git branch Flux should track | `"main"` |
| `flux_kustomization_path` | Path within the Git repository to reconcile | `"./flux/bootstrap/flux-system"` |
| `flux_sync_interval` | Interval at which Flux reconciles | `"1m"` |
| `flux_kustomization_name` | Name for the Kustomization resource | `"cluster-sync"` |

## Cluster Access

The cluster kubeconfig is stored at:
```
./kubeconfig.yaml
```

And automatically merged into `~/.kube/config` with context name:
```
kind-sre-control-plane
```

## Port Mappings

- `8080` → `30080` (HTTP NodePort)
- `8443` → `30443` (HTTPS NodePort)

## Cleanup

```bash
terraform destroy
```

This will delete the kind cluster and clean up all resources.

## Troubleshooting

### Check Flux Operator logs
```bash
kubectl -n flux-system logs -l app.kubernetes.io/name=flux-operator
```

### Check FluxInstance status
```bash
kubectl -n flux-system describe fluxinstance flux
```

### Check Flux controllers
```bash
kubectl -n flux-system get pods
kubectl -n flux-system logs -l app=source-controller
kubectl -n flux-system logs -l app=kustomize-controller
```

## Upgrading

See [UPGRADE.md](./UPGRADE.md) for detailed upgrade instructions for:
- Flux CLI
- Flux Operator
- Flux Controllers

## Documentation

- [Flux Operator Documentation](https://fluxcd.control-plane.io/operator/)
- [Flux Documentation](https://fluxcd.io/flux/)
- [Kind Documentation](https://kind.sigs.k8s.io/)
