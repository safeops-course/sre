# Progressive Delivery (Traefik + Flagger) - Chapter 19

A frontend release in `develop` reaches a share of the traffic first: Flagger runs the new version
as a canary, Traefik sends it 10%, 20% ... 50% of the requests, and the canary's own success rate
and latency decide - promoted, or rolled back after three failed checks.

- `flagger/` - the Flagger controller (Traefik provider, its metrics scraped). Always installed;
  idle without a Canary.
- `develop/` - **opt-in**: the frontend Canary, the IngressRoute users take while it is on,
  synthetic traffic for the analysis, and the alert `CanaryRolledBack`. Applied by
  `flux/bootstrap/flux-system/progressive-delivery-develop.yaml`, which is not listed in that
  directory's `kustomization.yaml`.
- Traefik's request metrics come from `observability/kube-prometheus-stack/monitoring/traefik-podmonitor.yaml`.

Only the frontend: static files and a proxy, no data - its rollback is the previous image and nothing
else. The backend owns a database; a canary of it needs a schema both versions run on (Chapter 18)
and a traffic split between services (a mesh or a gateway): not in this chapter.

## Enable / disable

Add `- progressive-delivery-develop.yaml` to the resources in
`flux/bootstrap/flux-system/kustomization.yaml` (pull request, merge). Then
`kubectl -n develop get canary frontend` turns `Initialized`, `frontend-primary` serves, and the
Deployment `frontend` stays at 0 between releases.

Remove the line again to disable. The Canary sets `revertOnDeletion: true`: Flagger scales
`frontend` back up and points the Service at it before it removes its primary objects; the
IngressRoute goes and the Ingress serves again. Without it the Service would keep selecting the
deleted primary and the Deployment could stay at 0 (an HPA does not scale up from 0).

## How traffic reaches the canary

- Users: Traefik -> IngressRoute `frontend-canary` (priority 1000) -> TraefikService `frontend`
  (Flagger: primary and canary, weighted). A Kubernetes Ingress cannot point at a TraefikService
  ("Resource backends are not supported"), so the route is an IngressRoute.
- The overlay's Ingress stays: external-dns (DNS record, `policy: sync`) and cert-manager
  (`frontend-tls`) read it on Hetzner - removing it would delete the record. Both match the host;
  the IngressRoute wins by its explicit priority (the default is the rule's length, and the
  Ingress's rule is longer).
- Analysis traffic: `frontend-synthetic-traffic` - two requests a second through Traefik over
  HTTPS. develop has no users, and a check with no requests fails.

## What went wrong before (2026-09-27)

Both apps had Canaries whose IngressRoutes matched `Host(backend.develop.svc.cluster.local)` - a
name nothing sends - and the frontend reaches the backend directly, not through Traefik. Prometheus
did not scrape Traefik at all. Every check found no values, every new develop release was rolled
back, and develop kept serving a March build; nothing alerted. On Hetzner those IngressRoutes would
also have let anyone reach every backend route through the load balancer with that Host header,
past the frontend's API allowlist. Removed; the analysis now has metrics, traffic and an alert.

## Not yet verified on Hetzner

On kind there is no external-dns and no cert-manager (Traefik's default certificate). On Hetzner:
that the IngressRoute serves `frontend-tls`, that external-dns keeps the record, and that
Traefik (the same Flux HelmRelease as on kind, chart defaults) exposes the `metrics` port. Check before enabling the module there.
