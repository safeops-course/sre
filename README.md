# SRE Control Plane (Guardrails-First)

This repository is the **production implementation** behind the [SafeOps SRE Course](https://safeops.work/). Every chapter in the course maps directly to real infrastructure, manifests, and scripts maintained here.

The code and the course are free. If they saved you an incident, [buy me a coffee ☕](https://buymeacoffee.com/ldbl).

The point is not "how to use AI" or "how to prompt". The point is how to build workflows where AI behaves like a fast, confident junior engineer (low context, no fear) while the surrounding system stays safe.

## Course ↔ Implementation Map

The course at [safeops.work](https://safeops.work/) teaches concepts; this repo contains the working code. See [`course-map.yml`](course-map.yml) for the full file-level mapping.

Topics are listed in course order. Chapter numbers live only in the course, so they can change without touching this repo.

| Topic | Implementation in this repo |
|-------|-----------------------------|
| Blast radius & the four rules | `scripts/guard-kube-context.sh`, `scripts/guard-terraform-plan.sh` |
| Infrastructure as Code | `infra/terraform/kind_cluster/`, `.pre-commit-config.yaml` |
| GitOps with Flux | `flux/bootstrap/`, `flux/apps/`, `flux/infrastructure/` |
| Secrets Management | `.sops.yaml`, `scripts/sops-encrypt-secret.sh`, `flux/secrets/` |
| CI/CD & Developer Guardrails | `.github/workflows/`, `.coderabbit.yml`, `.pre-commit-config.yaml` |
| Network Policies | `flux/infrastructure/network-policies/` |
| Security Context | `flux/apps/backend/base/deployment.yaml`, `flux/bootstrap/infrastructure/base/namespaces.yaml` |
| Resource Management | `flux/apps/backend/base/deployment.yaml`, `flux/infrastructure/resource-management/` |
| Availability Engineering | `flux/apps/backend/develop/`, `flux/apps/frontend/overlays/develop/` |
| Version Promotion | `flux/apps/backend/{develop,staging,production}/`, `flux/bootstrap/infrastructure/image-automation/` |
| Observability | `flux/infrastructure/observability/`, `flux/apps/backend/base/servicemonitor.yaml` |
| Backup & Restore | `flux/infrastructure/data/cnpg-clusters/`, `infra/terraform/hcloud_cluster/main.tf` |
| Controlled Chaos | `flux/infrastructure/chaos/develop/` |
| AI-Assisted SRE Guardian | `flux/` (full GitOps tree), `../k8s-ai-monitor/` |
| 24/7 Production SRE | Cross-cutting - observability + alerting + runbooks |
| Admission Policy Guardrails (advanced) | `flux/infrastructure/policy/kyverno/`, `flux/infrastructure/policy/packs/admission-guardrails/` |
| Supply Chain Security (advanced) | `flux/infrastructure/policy/packs/supply-chain/` |
| Rollback & Data Migrations (advanced) | `flux/infrastructure/data/cnpg-clusters/` |
| Progressive Delivery (advanced) | `flux/infrastructure/progressive-delivery/` |

## Repository Layout

- `docs/` -- living platform docs (architecture, runbooks, GitOps workflows)
- `infra/` -- Terraform IaC
- `infra/terraform/hcloud_cluster/` -- Hetzner k3s production cluster (kube-hetzner module)
- `infra/terraform/kind_cluster/` -- local multi-node kind cluster + Flux install
- `flux/` -- FluxCD GitOps configuration (bootstrap, infrastructure, apps, secrets)
- `config/` -- shared configuration files
- `tests/` -- infrastructure and system test suites
- `scripts/` -- helper scripts, automation wrappers, pre-commit hooks
- `course-map.yml` -- auto-generated mapping of files to course chapters

Companion repos in this workspace:
- `../backend/` -- Go HTTP API reference service (health probes, Prometheus metrics, OpenTelemetry traces, chaos endpoints)
- `../frontend/` -- Vue 3 SPA dashboard (health dashboard, API explorer, chaos controls, web tracing)
- `../k8s-ai-monitor/` -- Kopf-based K8s monitoring operator with LLM-powered root-cause analysis (Ch 13)

## Current Decisions

- Repository model: control-plane repo (`sre/`) plus companion service repos (`backend/`, `frontend/`) in the same workspace
- Local Kubernetes: kind
- GitOps operator: FluxCD
- IaC: Terraform under `infra/terraform`; GitOps manifests under `flux/`
- Automation: `scripts/` for reusable tooling, `tests/` for infrastructure tests

## Quick Start

1. **Hetzner cluster** (recommended): follow `docs/hetzner.md`.
2. **Local cluster** (optional): follow `docs/local-dev.md` to provision kind via Terraform.

### Local kind (Optional)

1. Install system prerequisites: Docker (running), `curl`, `tar`, `unzip`.
2. Install the Kubernetes/IaC CLIs manually (recommended versions): Terraform 1.16.4, kubectl 1.36.5, kind 0.33.0, flux 2.9.5.
3. Provision the local kind cluster via Terraform (`infra/terraform/kind_cluster`) -- this installs Flux and reconciles the **local profile** (`flux/bootstrap/profiles/local`): the platform without its cloud-only parts, with MinIO standing in for R2 and Terraform-generated runtime secrets. `flux get kustomizations -A` should be all green.
4. Follow `docs/local-dev.md` for what the local profile includes, how to point it at your fork, and the verification commands.

The full platform profile (`./flux/bootstrap/flux-system`) is what Hetzner runs; select it with `TF_VAR_flux_kustomization_path` once you have the cloud secrets. See `docs/gitops/flux.md`.

## Where To Start Reading

- Course website: [safeops.work](https://safeops.work/)
- Course source repo: [`sre-course`](https://github.com/safeops-course/sre)
- AI guardrails: `docs/ai-code-of-conduct.md`
- Hetzner cluster: `docs/hetzner.md`
- Local bootstrap: `docs/local-dev.md`
- Flux/GitOps: `docs/gitops/flux.md`

Track build-out progress in `PLAN.md`.
