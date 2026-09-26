# CLAUDE.md — SRE DevOps Repository

## AI Agent Guidance

### Repository Context

This is the SRE DevOps infrastructure repository, responsible for managing k3s clusters on Hetzner Cloud via Terraform IaC and FluxCD GitOps. It contains the reference backend/frontend services, observability stack, and the platform implementation that the separate `sre-course` repository teaches from. Terraform uses remote state in Cloudflare R2 with per-environment namespace isolation via FluxCD overlays.

### AI Agent Operating Principles

**Critical Instructions for AI Agents:**

- **Tool Result Reflection**: After receiving tool results, carefully reflect on their quality and determine optimal next steps before proceeding. Use your thinking to plan and iterate based on this new information, and then take the best next action.
- **Parallel Execution**: For maximum efficiency, whenever you need to perform multiple independent operations, invoke all relevant tools simultaneously rather than sequentially.
- **Temporary File Management**: If you create any temporary new files, scripts, or helper files for iteration, clean up these files by removing them at the end of the task.
- **High-Quality Solutions**: Write high quality, general purpose solutions. Implement solutions that work correctly for all valid inputs, not just specific cases. Do not hard-code values or create solutions that only work for specific scenarios.
- **Problem Understanding**: Focus on understanding the problem requirements and implementing the correct approach. Provide principled implementations that follow best practices and software design principles.
- **Feasibility Assessment**: If the task is unreasonable or infeasible, say so. The solution should be robust, maintainable, and extendable.

### Zen Principles of This Repo

*Inspired by PEP 20 — The Zen of Python, applied to infrastructure code:*

- **Beautiful is better than ugly** — Clean, readable Terraform/YAML over complex nested expressions
- **Explicit is better than implicit** — Clear variable names and documented intentions
- **Simple is better than complex** — Straightforward logic over clever abstractions
- **Complex is better than complicated** — When complexity is needed, make it organized not chaotic
- **Readability counts** — Code is read more often than written
- **Special cases aren't special enough to break the rules** — Consistency over exceptions
- **Errors should never pass silently** — Fail loud and early with clear messages
- **In the face of ambiguity, refuse the temptation to guess** — Test and verify, don't assume
- **If the implementation is hard to explain, it's a bad idea** — Complex patterns need clear documentation
- **If the implementation is easy to explain, it may be a good idea** — Simple solutions are often best
- **If you need a decoder ring to understand the code, rewrite it simpler** — No hieroglyphs!
- **There should be one obvious way to do it** — Establish patterns and stick to them
- **Be humble enough to build systems that are better than you** — Create safeguards that protect against human error, forgetfulness, and AI session resets

### Core Philosophical Principles

**KISS (Keep It Simple, Stupid)** — The fundamental principle guiding ALL decisions in this repository:
- Keep it simple and don't over-engineer solutions
- No hieroglyphs — code should be readable by humans, not just compilers
- Avoid complex regex patterns when simple logic works
- Replace nested function calls with clear step-by-step operations
- Use descriptive comments for complex validation logic
- If you need a decoder ring to understand the code, rewrite it simpler

**The "Be Humble" Principle** — Create safeguards that protect against:
- Human error and oversight
- AI session resets and context loss
- Complex edge cases that might be forgotten
- Future developers who may not understand the original intent

## Project Structure

```
infra/terraform/
  hcloud_cluster/    # Hetzner k3s cluster (kube-hetzner module)
  kind_cluster/      # Local development cluster
flux/
  bootstrap/         # FluxCD bootstrap (kustomizations, secrets)
  infrastructure/    # Helm releases (cert-manager, external-dns, prometheus, cnpg)
  apps/              # Application deployments (frontend, backend per environment)
  secrets/           # SOPS-encrypted secrets
backend/             # Go reference service (health, metrics, chaos endpoints)
frontend/            # Vue 3 SRE dashboard (Vite + Tailwind + nginx)
scripts/             # Pre-commit hooks, automation scripts
  docs/                # Platform runbooks, architecture notes, and repo pointers
```

## Key Technologies

- **IaC**: Terraform with kube-hetzner module (MicroOS, k3s)
- **GitOps**: FluxCD (Flux Operator + FluxInstance, Kustomizations, HelmReleases)
- **Secrets**: SOPS with AGE encryption
- **DNS/TLS**: external-dns + cert-manager (Cloudflare DNS-01)
- **Ingress**: Traefik (via kube-hetzner)
- **Observability**: kube-prometheus-stack (Prometheus, Grafana) + k8s-ai-monitor (AI-assisted alert routing)
- **Database**: CloudNativePG
- **State**: Terraform remote state in Cloudflare R2 (S3-compatible)

## Critical Rules

### Infrastructure Safety
- **NEVER** run `terraform apply` or `terraform destroy` without explicit user approval
- **NEVER** commit secrets, kubeconfig files, .key, .pem, or .env files
- **NEVER** commit directly to main/master — always use feature branches
- **NEVER** amend commits that have been pushed to remote

### Terraform
- State is remote in R2 — never delete state files manually without understanding implications
- Use `make destroy` (not bare `terraform destroy`) — it handles Flux/k8s resource cleanup first
- All sensitive variables come via `TF_VAR_*` from `load-env.sh`
- `.tfvars` files are gitignored — use `terraform.tfvars.example` as template

### FluxCD / Kubernetes
- Environments: develop, staging, production — each has its own namespace and overlays
- Kustomize overlays pattern: `base/` + `overlays/{develop,staging,production}/patches/`
- SOPS secrets go in `flux/secrets/` with `.sops.yaml` rules per directory
- cert-manager (namespace `cert-manager`) and external-dns (namespace `external-dns`) each read the
  Cloudflare DNS token from their own SOPS Secret `cloudflare-api-token` (flux/secrets/cloudflare)
- NetworkPolicies use `default-deny-all` — new services need explicit ingress/egress rules from `traefik` namespace

### Resource Management
- ResourceQuotas enforce per-namespace limits (develop/staging: 500m CPU, 512Mi; production: 1 CPU, 1Gi)
- LimitRange sets defaults (10m/64Mi request) — cert-manager ACME solver needs min 10m CPU
- Production: 2 replicas with higher requests; develop/staging: 1 replica with minimal requests

## Make Targets

### Root Makefile
- `make install-hooks` — install all pre-commit hooks
- `make pre-commit` — run all hooks manually
- `make fmt` — terraform fmt recursive
- `make validate` — terraform validate
- `make terraform-hcloud-plan` — init + plan for Hetzner cluster
- `make terraform-hcloud-apply` — init + apply
- `make terraform-hcloud-destroy` — init + destroy (with state cleanup)

### hcloud_cluster Makefile
- `make init` / `make plan` / `make apply` / `make destroy`
- `make test` — validate terraform configuration
- `make state-clean` — remove all resources from remote state
- `make state-clean-k8s` — remove only kubernetes resources from state
- `make kubeconfig` — print KUBECONFIG export command

## Git Workflow

1. Create feature branch from main
2. Make changes, run `make pre-commit`
3. Push and create PR — CodeRabbit reviews automatically
4. GitHub Actions runs `terraform plan` on PR
5. Merge to main — apply via `workflow_dispatch` with approval gate

## Coding Style

- 2 spaces for YAML, HCL (Terraform), shell scripts
- Shell scripts: `set -e` minimum, `set -Eeuo pipefail` for critical scripts
- Terraform: pin chart/module versions, use meaningful resource names
- YAML: use `---` document separator, consistent indentation
- Keep it simple — KISS principle guides all decisions
