# Progressive Delivery (Traefik + Flagger)

This directory contains optional GitOps manifests for the advanced module:
- Flagger controller configured for Traefik provider
- `develop` canary examples with MetricTemplates and IngressRoutes

Current bootstrap behavior:
- Flagger controller is enabled in
  `flux/bootstrap/flux-system/infrastructure.yaml`.
- `develop` canary sample resources remain opt-in (commented Flux
  Kustomization).

## Prerequisites

1. Cluster observability stack is running (Prometheus endpoint available).
2. Traefik ingress controller is running (deployed via kube-hetzner).

## Enable Develop Canary Samples

1. Uncomment `progressive-delivery-develop` Kustomization in:
   - `flux/bootstrap/flux-system/infrastructure.yaml`
2. Reconcile Flux and validate with:
   - `kubectl -n develop get canary`
   - `kubectl -n develop get traefikservice`
