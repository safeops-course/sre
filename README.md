# SRE Control Plane (Guardrails-First)

This repository is a production-grade demo control plane plus two reference services. It is designed to teach how to use AI in DevOps / SysOps / SRE **without increasing risk or blast radius**.

The point is not “how to use AI” or “how to prompt”. The point is how to build workflows where AI behaves like a fast, confident junior engineer (low context, no fear) while the surrounding system stays safe.

## Current Decisions
- Repository model: control-plane repo (`sre/`) plus companion service repos (`backend/`, `frontend/`) in the same workspace
- Local Kubernetes: kind
- GitOps operator: FluxCD
- IaC layout: Terraform under `infra/terraform`; GitOps manifests under `flux/`
- Automation: `scripts/` for reusable tooling, `tests/` for infrastructure tests

## Repository Layout
- `docs/` – living platform docs (architecture, runbooks, GitOps workflows)
- `infra/` – Terraform
- `infra/terraform/kind_cluster/` – Terraform module (tehcyx/kind) defining the local multi-node kind cluster + Flux install
- `flux/` – FluxCD GitOps configuration
- `config/` – shared configuration files
- `tests/` – infrastructure and system test suites
- `scripts/` – helper scripts, automation wrappers

Companion repos in this workspace:
- `../backend/` – Go HTTP API reference service (logging baseline, Prometheus metrics, OpenTelemetry traces, chaos endpoints)
- `../frontend/` – Vue 3 SPA demo UI (dashboard, API explorer, chaos controls, web tracing)

## Quick Start
1. Hetzner cluster (recommended): follow `docs/hetzner.md`.
2. Local cluster (optional): follow `docs/local-dev.md` to provision kind via Terraform.

## Local kind (Optional)
1. Install system prerequisites: Docker (running), `curl`, `tar`, `unzip`.
2. Install the Kubernetes/IaC CLIs manually (recommended versions): Terraform 1.13.3, kubectl 1.34.1, kind 0.30.0, flux 2.7.0.
3. Provision the local kind cluster via Terraform (`infra/terraform/kind_cluster`) – this also installs Flux controllers automatically.
4. Follow `docs/local-dev.md` for extra tips (Terraform workflow, local registry, manual commands) and advanced workflows.

To enable GitOps reconciliation of this repository, set `TF_VAR_flux_git_repository_url` (and optional branch/path variables) before running Terraform. The default sync path is `./flux/bootstrap/flux-system`. See `docs/gitops/flux.md` for details.

## Where To Start Reading
- Course website/content has moved to separate repository: `https://github.com/ldbl/sre-course`
- AI guardrails: `docs/ai-code-of-conduct.md`
- Hetzner cluster: `docs/hetzner.md`
- Local bootstrap: `docs/local-dev.md`
- Flux/GitOps: `docs/gitops/flux.md`

Track build-out progress in `PLAN.md`.
