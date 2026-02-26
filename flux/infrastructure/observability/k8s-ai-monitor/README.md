# k8s-ai-monitor (Observability Alert Router)

This module deploys `k8s-ai-monitor` in namespace `observability` as the primary alert routing path.

## What It Does

- Watches Kubernetes/Flux health signals.
- Pulls context from Kubernetes APIs and Prometheus.
- Performs AI-assisted incident triage.
- Sends notifications to a Slack-compatible webhook endpoint.

## OpsGenie Integration

`k8s-ai-monitor` currently posts through `SLACK_WEBHOOK_URL`.
For OpsGenie, point this value to:

- an OpsGenie Slack-compatible integration endpoint, or
- a webhook relay that forwards to OpsGenie Alerts API.

## Required Secret

Copy and encrypt:

- `flux/secrets/observability/k8s-ai-monitor-secrets.yaml.example`
  -> `flux/secrets/observability/k8s-ai-monitor-secrets.yaml`

Then uncomment this file in:

- `flux/secrets/observability/kustomization.yaml`

## Runtime Endpoints

- health: `GET /healthz`
- state: `GET /state`
- reports: `GET /reports`

Service name:

- `k8s-ai-monitor.observability.svc.cluster.local:8080`
