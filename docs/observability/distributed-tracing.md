# Distributed Tracing

How one request is traced from the browser through the backend to its database queries, and where
this repository configures it. What each application's SDK does - initialization, instrumentations,
span names, errors - is in its own repository, next to the code:
[frontend `TELEMETRY.md`](https://github.com/safeops-course/frontend/blob/main/TELEMETRY.md),
[backend `TELEMETRY.md`](https://github.com/safeops-course/backend/blob/main/TELEMETRY.md). This page
does not copy their code: a copy here goes out of date the first time the code changes.

The parts:
- **Frontend (browser)**: Vue 3 with the OpenTelemetry Web SDK; sends its spans to Uptrace itself.
- **Backend (Go)**: the OpenTelemetry SDK; sends traces, metrics and logs to Uptrace itself.
- **OpenTelemetry collectors** (in the cluster): pod logs, kubelet metrics and Kubernetes Events
  (`docs/observability/logs.md`) - not the traces of the frontend or the backend.
- **Uptrace Cloud**: stores and shows the traces (`docs/observability/uptrace-cloud.md`).

## Architecture

```
┌──────────────────────────────────────┐
│ Browser: Frontend (Vue 3 + OTel Web) │  spans, OTLP/HTTP (VITE_UPTRACE_DSN)
│ - click "Get Version": span xyz      │─────────────────────────────┐
│ - GET /api/version                   │                             │
│   traceparent: 00-abc123-xyz-01      │                             │
└──────────────────┬───────────────────┘                             │
                   │ request                                         │
┌──────────────────┼──────────────────────────┐                      │
│ Kubernetes Cluster                          │                      │
│                  ▼                          │                      ▼
│  ┌────────────────────────────────────┐     │  spans,     ┌──────────────────┐
│  │ Backend (Go + OTel SDK)            │─────┼────────────▶│ Uptrace Cloud ☁️  │
│  │ - reads traceparent, child span    │     │  OTLP/HTTP  │                  │
│  └────────────────────────────────────┘     │  (UPTRACE_  │ Trace: abc123    │
│                                             │   DSN)      │  ├─ Frontend     │
│  ┌────────────────────────────────────┐     │             │  │  └─ HTTP GET  │
│  │ OTel Collectors: pod logs, kubelet │─────┼────────────▶│  └─ Backend      │
│  │ metrics, Kubernetes Events         │     │  logs,      │     └─ Handler   │
│  └────────────────────────────────────┘     │  metrics    └──────────────────┘
└─────────────────────────────────────────────┘
```

## Where This Repository Configures It

Both applications read the same DSN, key `uptrace-dsn` of the Secret `backend-secrets` in each
environment's namespace (`docs/observability/uptrace-cloud.md`, section 2; rotating it:
`docs/credential-rotation.md`).

| | Frontend (`flux/apps/frontend/base/deployment.yaml`) | Backend (`flux/apps/backend/base/deployment.yaml`) |
|---|---|---|
| Where spans go | `VITE_UPTRACE_DSN` | `UPTRACE_DSN`, `OTEL_EXPORTER_OTLP_HEADERS` (key `uptrace-headers`, may be empty) |
| `service.name` | `frontend` (fixed in the code) | `SERVICE_NAME` (`backend`) |
| `service.version` | the image's own tag | the version baked into the image (the same as `/version`) |
| `deployment.environment.name` | `ENVIRONMENT` | `DEPLOYMENT_ENVIRONMENT` |
| Cluster, namespace, pod | - (see below) | `OTEL_RESOURCE_ATTRIBUTES`: `k8s.cluster.name`, `k8s.namespace.name`, `k8s.pod.name` |

The frontend's container writes its runtime settings into `/config.js` when it starts, and the browser
reads them from there - so the DSN reaches every visitor. That is by design: the DSN can only send data
into the Uptrace project, not read it. The Deployment also sets `CLUSTER_NAME`, but the image does not
write it into `/config.js` yet, so frontend spans carry no `k8s.cluster.name` (a fix in the frontend
repository).

## One Trace from the Click to the Database

1. The browser starts a span for the action (`ui.<view>.<action>`) and one for the HTTP call.
2. It adds the W3C trace context to the request - only to URLs it is told to (the page's API origin,
   `*.safeops.work`, `localhost`, `*.local`, `*.svc.cluster.local`), so no other site sees it:

   ```
   traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
                │  │                                │                └─ flags (01 = sampled)
                │  └─ trace id (32 hex)             └─ the caller's span id (16 hex)
                └─ version
   ```

3. The request goes to `/api/` on the page's own origin; the frontend's nginx passes it to the backend.
   Same origin: no CORS, nothing for the backend to allow.
4. The backend reads `traceparent` and creates its span as a child, named after the route
   (`GET /delay/{seconds}`), and one span per database query.
5. Each side exports its own spans; Uptrace joins them by the trace id.

Probes and metrics scrapes (`/healthz`, `/readyz`, `/livez`, `/metrics`) are traced on neither side:
they would be most of the spans and say nothing about users.

## Checking It

On a running environment, open the site with the browser's developer tools:

1. The console shows `[Telemetry] OpenTelemetry initialized successfully`; `No Uptrace DSN or collector
   URL configured: spans are not exported` means `VITE_UPTRACE_DSN` was empty.
2. The network tab shows `POST https://api.uptrace.dev/v1/traces` answered with 200.
3. A test request in the API Explorer appears in Uptrace as a `ui.api_explorer.test_endpoint` span, with
   the backend's span and its database spans in the same trace.

From the cluster (the DSN itself is never printed):

```bash
# the frontend's runtime config holds a DSN: 1 = yes, 0 = empty
kubectl -n develop exec deploy/frontend -- grep -c 'VITE_UPTRACE_DSN: "https://' /tmp/config.js
# the backend exports: "OpenTelemetry initialized: service=backend version=... env=..."
kubectl -n develop logs deploy/backend -c backend | grep -m1 OpenTelemetry
```

When spans do not arrive:

- **Browser**: a console warning `... is not allowed by the CSP ...; spans are not exported` - the image
  allows `connect-src` only to its own origin and `https://api.uptrace.dev`.
- **Backend**: `OpenTelemetry running without Uptrace export: UPTRACE_DSN is not set`, or
  `OpenTelemetry error: ...` lines; whether the namespace may reach Uptrace at all (NetworkPolicy
  egress): `docs/observability/uptrace-cloud.md`, *Backend Not Sending Telemetry*.
- **Two traces instead of one**: the request's URL did not get `traceparent` - the API was called on an
  origin the frontend does not propagate to.

## Writing Good Spans

- **Bounded names**: the route pattern (`GET /users/{id}`), never the raw path (`GET /users/123`) - each
  distinct name is a group of its own in Uptrace.
- **Attributes, not text**: `order.items.count = 3`, not a formatted dump of an object.
- **Errors on the span**: record the exception and set the status to ERROR where it is handled, so the
  trace shows where it failed.
- **No secrets or personal data**: no passwords, tokens or API keys; no e-mail addresses or phone
  numbers - spans are kept and read by more people than the database.
