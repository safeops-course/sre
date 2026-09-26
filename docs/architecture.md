# Architecture Overview

## Technical Stack Decisions
- **Frontend:** Vue 3 SPA (Vite) served by nginx in containerized deployments.
- **Backend:** Go 1.24 HTTP API with health probes, metrics, OpenAPI/Swagger, chaos endpoints, and tracing hooks.
- **Kubernetes runtime:** Hetzner Cloud k3s is the primary path; kind remains the local/dev path.
- **GitOps operator:** Flux (installed via Flux Operator + `FluxInstance` in Terraform).
- **Infrastructure as code:** Terraform under `infra/terraform/`.
- **Manifests:** Flux + Kustomize under `flux/`.
- **Observability:** kube-prometheus-stack (Prometheus, Grafana) + k8s-ai-monitor for AI-assisted alert routing and triage.

## Current Repository Scope
This repository (`sre/`) is the control plane and GitOps source of truth.

- `infra/terraform/hcloud_cluster/` - Hetzner cluster provisioning + Flux bootstrap.
- `infra/terraform/kind_cluster/` - local kind cluster provisioning + Flux bootstrap.
- `flux/` - GitOps manifests for apps, infrastructure, and secrets.
- `docs/` - architecture, runbooks, and workflow docs.
- `scripts/` - helper scripts (repo setup, SOPS setup, encryption helpers).
- `tests/` - reserved for infra/system tests (currently minimal scaffold).

Reference services are maintained as companion repos (`backend/`, `frontend/`) in this workspace and publish container images to GHCR, consumed by Flux from this control-plane repo.

## Flux and Environment Model
- Namespaces: `develop`, `staging`, `production`, plus `observability` and `flux-system`.
- Bootstrap path: `flux/bootstrap/flux-system`.
- App wiring per environment:
  - `flux/bootstrap/apps/develop/`
  - `flux/bootstrap/apps/staging/`
  - `flux/bootstrap/apps/production/`
- Backend manifests:
  - base: `flux/apps/backend/base/`
  - overlays: `flux/apps/backend/develop|staging|production/`
- Frontend manifests:
  - base: `flux/apps/frontend/base/`
  - overlays: `flux/apps/frontend/overlays/develop|staging|production/`

## Delivery and Promotion Flow
1. `backend` and `frontend` build workflows publish GHCR images on push to `develop`/`main`.
2. Flux `ImageRepository` + `ImagePolicy` objects discover newest env-specific tags.
3. Flux `ImageUpdateAutomation` writes new tags back to this repo (`main`) using setters.
4. Flux reconciles updated manifests into `develop`/`staging`/`production`.
5. Production image promotion is manual (`workflow_dispatch`) in service repos and re-tags staging images to `production-*`, which Flux then deploys.

## Observability Status
- Deployed by Flux via `flux/infrastructure/observability/kube-prometheus-stack/`.
- Includes dashboards and alert rules for backend service metrics.
- Alertmanager is disabled; alert delivery path is `k8s-ai-monitor` webhook routing.
- `k8s-ai-monitor` is deployed via `flux/infrastructure/observability/k8s-ai-monitor/` and uses Prometheus + Kubernetes context for incident analysis.
- OpenTelemetry collector manifests exist under `flux/infrastructure/observability/opentelemetry-collector/`; bootstrap wiring is currently disabled (commented in `flux/bootstrap/flux-system/infrastructure.yaml`).

## Secrets and Security Model
- Secrets are committed as SOPS-encrypted manifests under `flux/secrets/**`.
- Flux decryption uses the `sops-age` secret in `flux-system`, written by Terraform from the ephemeral `TF_VAR_sops_age_key` (`data_wo`: never in the plan or the state).
- GHCR pull credentials are optional and created by Terraform when enabled.
- Guardrails and AI operating rules are defined in `docs/ai-code-of-conduct.md`.
