# Kind Cluster with Flux Operator

This Terraform configuration creates a local Kubernetes cluster using [kind](https://kind.sigs.k8s.io/) and installs the [Flux Operator](https://fluxcd.control-plane.io/operator/) for GitOps continuous delivery.

## Architecture

- **Kind Cluster**: 1 control-plane node + 1 worker node
- **Flux Operator**: Installed with `kubectl apply` from the Flux Operator release manifest
- **FluxInstance**: Deploys all Flux controllers (source, kustomize, helm, notification, image-reflector, image-automation)
- **Optional GitOps Bootstrap**: Automatically connects to your Git repository

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Terraform](https://www.terraform.io/downloads.html) >= 1.11 (write-only attributes; `required_version` in main.tf)
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
1. Create a kind cluster named `sre-control-plane` (+ metrics-server; Traefik comes from Flux)
2. Install the Flux Operator
3. Deploy a FluxInstance with all Flux controllers, syncing `./flux/bootstrap/profiles/local` from the course repo
4. Generate the local runtime secrets (JWT, Postgres owner, MinIO, sops-age from `age.agekey`) - see `local-profile.tf`
5. Merge the kubeconfig into your `~/.kube/config`

Defaults target the SafeOps course repo and the local profile. Working from a fork, set `flux_git_repository_url` in `terraform.tfvars` (copy `terraform.tfvars.example`; Git ignores the file) - not in an `export`, which a plan from another terminal would not see, pointing Flux back at the course repo. For the full platform, `TF_VAR_flux_kustomization_path=./flux/bootstrap/flux-system` for that run (`docs/local-dev.md`).

### 3. Verify Installation

```bash
# Check cluster
kubectl cluster-info --context kind-sre-control-plane

# Check Flux Operator
kubectl --context kind-sre-control-plane -n flux-system get pods

# Check FluxInstance
kubectl --context kind-sre-control-plane -n flux-system get fluxinstance
```

## Your Fork, a Private Copy

Flux follows the course repository unless `terraform.tfvars` names your fork:

```hcl
flux_git_repository_url = "https://github.com/YOUR_GITHUB_USER/sre.git"
```

A fork of a public repository is public, and Flux reads it anonymously. A private copy needs a fine-grained token with `Contents: Read-only` for that one repository - read it into the shell, never into a file or the command line:

```bash
printf 'GitHub PAT: '; IFS= read -rs TF_VAR_flux_git_token; echo; export TF_VAR_flux_git_token
```

## Configuration Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `flux_git_repository_url` | Git repository Flux syncs from | `"https://github.com/safeops-course/sre.git"` |
| `flux_git_repository_branch` | Git branch Flux tracks | `"main"` |
| `flux_kustomization_path` | Path within the repository to reconcile | `"./flux/bootstrap/profiles/local"` |
| `flux_sync_interval` | Interval at which Flux reconciles | `"1m"` |
| `flux_kustomization_name` | Name of the sync Kustomization | `"cluster-sync"` |
| `flux_git_token` | Token for a private copy (`TF_VAR_flux_git_token`) | `""` |

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
kubectl --context kind-sre-control-plane -n flux-system logs -l app.kubernetes.io/name=flux-operator
```

### Check FluxInstance status
```bash
kubectl --context kind-sre-control-plane -n flux-system describe fluxinstance flux
```

### Check Flux controllers
```bash
kubectl --context kind-sre-control-plane -n flux-system get pods
kubectl --context kind-sre-control-plane -n flux-system logs -l app=source-controller
kubectl --context kind-sre-control-plane -n flux-system logs -l app=kustomize-controller
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
