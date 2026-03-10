# Local Development Environment

This repo supports:
- a local `kind` cluster (fast feedback loop), and
- a Hetzner Cloud cluster (provider-realistic).

If you are using Hetzner as the primary environment, start with `docs/hetzner.md`.

Use Terraform to provision a local multi-node kind cluster. Terraform manages lifecycle and kubeconfig generation so you can focus on deploying workloads.

## Prerequisites
- Docker Engine running with adequate CPU/RAM for at least three nodes
- `curl`, `tar`, and `unzip` available on your workstation
- Go 1.24+ and Node.js 20+ with npm for backend/frontend development
- `make` (GNU make recommended)
- Terraform 1.3+ and `kubectl`

## Provision the Cluster with Terraform
Use the Terraform module under `infra/terraform/kind_cluster/` to create (or destroy) the local kind cluster. The module codifies the multi-node topology directly in Terraform, automatically merges the generated kubeconfig into `~/.kube/config`, and bootstraps Flux via Flux Operator + `FluxInstance`.
Optionally, configure GitOps reconciliation by setting:
```bash
export TF_VAR_flux_git_repository_url="https://github.com/safeops-course/sre.git"
export TF_VAR_flux_git_repository_branch="main"
export TF_VAR_flux_kustomization_path="./flux/bootstrap/flux-system"
```
before applying Terraform. Flux will then watch the specified path inside your Git repository.
```bash
cd infra/terraform/kind_cluster
terraform init
terraform apply
```
The Terraform workflow creates the three-node topology (one control plane, two workers), writes a kubeconfig alongside the module (`kubeconfig.yaml`), and becomes the single source of truth for lifecycle operations.

### Configure Kubeconfig Context
Point kubectl to the generated kubeconfig and switch context:
```bash
export KUBECONFIG="$(pwd)/infra/terraform/kind_cluster/kubeconfig.yaml"
kubectl config use-context sre-control-plane
```
Terraform automatically merges the kubeconfig into your default config (`~/.kube/config`) and ensures the context `sre-control-plane` is available.

## Configure Local Registry (Optional but Recommended)
Run a local container registry to speed up iterative image pushes:
```bash
docker run -d --restart=always -p 5001:5000 --name kind-registry registry:2
```
Ensure the registry is running before applying Terraform so the mirror entry in the cluster configuration is valid.

## Destroy the Cluster
Use Terraform to tear down the environment when finished:
```bash
cd infra/terraform/kind_cluster
terraform destroy
```

## Next Steps
- Review `docs/gitops/flux.md` for Flux usage; controllers are installed automatically by Terraform.
- Apply baseline namespaces and infrastructure from `flux/bootstrap/infrastructure/base/` and observability from `flux/infrastructure/observability/`.
- Build and run the backend locally: `cd backend && go run ./cmd/api`, then curl `http://localhost:8080/healthz` or scrape `http://localhost:8080/metrics`.
- Build the container image via `make -C backend image` and push it to your preferred registry (kind can use the local mirror at `localhost:5001`).
- Publish the production-ready image to GitHub Container Registry with `make backend-publish` (or `make -C backend publish`). Export `DOCKER_PAT` (PAT with `write:packages`) and optionally `DOCKER_USER` beforehand; override `REGISTRY_HOST`/`REGISTRY_NAMESPACE`/`IMAGE_NAME`/`TAG` as needed.
- The image build embeds git metadata (`APP_VERSION`, `APP_COMMIT`, `APP_COMMIT_SHORT`, `APP_BUILD_DATE`) via Go ldflags; `APP_VERSION` defaults to the latest annotated tag (SemVer). Override it when publishing a release and verify `/version` reflects your build (including `build_time`).
- Run `make test` (executes Go unit tests; Vue tests pending) before committing.
- Explore the API via `http://localhost:8080/swagger` for Swagger UI or `http://localhost:8080/openapi` for the raw spec.
