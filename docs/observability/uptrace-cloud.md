# Uptrace Cloud Integration

This guide covers the Uptrace Cloud integration for unified observability (logs, traces, and metrics).

> Which logs the in-cluster collectors read, and which they do not: `docs/observability/logs.md`.

## Overview

**Uptrace Cloud** is a managed OpenTelemetry-native observability platform that provides:
- **Distributed Tracing**: Request flows across microservices
- **Metrics**: Application and infrastructure metrics
- **Logs**: Structured and unstructured logs with correlation
- **Unified View**: All telemetry in one platform with automatic correlation

**Why Uptrace Cloud vs Self-Hosted?**
- ✅ Zero infrastructure management (no ClickHouse, PostgreSQL setup)
- ✅ Automatic scaling and updates
- ✅ Built-in high availability
- ✅ Perfect for demos and training environments
- ✅ Free tier available

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                        │
│                                                                  │
│  ┌──────────────┐        ┌────────────────────────────────┐     │
│  │   Backend    │        │ OTel Collectors                │     │
│  │ (Go + OTel)  │        │ DaemonSet: pod logs, kubelet   │     │
│  └──────────────┘        │ metrics, OTLP :4317/:4318      │     │
│         │                │ Deployment: Kubernetes Events  │     │
│         │                └────────────────────────────────┘     │
│         │ OTLP/HTTP + DSN              │ OTLP/HTTP + DSN        │
└─────────┼──────────────────────────────┼────────────────────────┘
          │  (traces, metrics, logs)     │
          ▼                              ▼
                  ┌─────────────────┐
                  │ Uptrace Cloud ☁️ │
                  │ api.uptrace.dev  │
                  └─────────────────┘
```

The backend exports straight to Uptrace ([`TELEMETRY.md` of the backend repository](https://github.com/safeops-course/backend/blob/main/TELEMETRY.md)), not through the collector. The
collector's OTLP receivers (gRPC 4317, HTTP 4318) are there for other applications.

## Setup Instructions

### 1. Sign Up for Uptrace Cloud

1. Visit https://uptrace.dev
2. Click "Sign Up" and create an account
3. After login, go to https://app.uptrace.dev/projects
4. Create a new project (e.g., "SRE Demo")
5. Copy your **DSN (Data Source Name)**

The DSN format:
```
https://<token>@api.uptrace.dev?grpc=4317
```

### 2. Give the DSN to the Backend and the Collectors

The backend reads the DSN from the Secret `backend-secrets` in its namespace (key `uptrace-dsn`; the Deployment also
maps key `uptrace-headers` to `OTEL_EXPORTER_OTLP_HEADERS`, which the backend ignores - it sends only the
`uptrace-dsn` header - so it may stay empty). On a cloud cluster it is a
SOPS file per environment, `flux/secrets/<env>/backend-secrets.yaml`:

```bash
# Edit with SOPS (decrypts in your editor, encrypts on save)
sops flux/secrets/develop/backend-secrets.yaml

# Set the DSN:
stringData:
  uptrace-dsn: "https://YOUR-TOKEN@api.uptrace.dev?grpc=4317"
```

On kind, Terraform generates `backend-secrets` (`infra/terraform/kind_cluster/local-profile.tf`).

The collectors take the DSN from `cluster-secrets`, written by Terraform (`uptrace_dsn`).

### 3. Deploy OpenTelemetry Collector

Flux installs two collectors (the component `flux/bootstrap/components/opentelemetry`, in every profile;
on kind they print to their own log instead): a DaemonSet for pod logs, OTLP and kubelet metrics, and a one-replica Deployment for Kubernetes
Events (`docs/observability/logs.md`).

```bash
kubectl -n observability get pods -l app.kubernetes.io/name=opentelemetry-collector
kubectl -n observability logs -l app.kubernetes.io/name=opentelemetry-collector --tail=50
```

### 4. Backend Instrumentation

The Go backend is instrumented with:

#### Dependencies
```go
github.com/uptrace/uptrace-go
go.opentelemetry.io/otel
go.opentelemetry.io/otel/sdk
go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
```

#### Initialization
```go
// cmd/api/main.go
shutdown := telemetry.Init(ctx)
defer shutdown()
```

#### HTTP Middleware
```go
// pkg/server/server.go
r.Use(telemetry.HTTPMiddleware)
```

#### Environment Variables
The backend deployment includes:
```yaml
env:
  - name: SERVICE_NAME
    value: "backend"
  - name: DEPLOYMENT_ENVIRONMENT
    value: "${ENVIRONMENT}"
  - name: UPTRACE_DSN
    valueFrom:
      secretKeyRef:
        name: backend-secrets
        key: uptrace-dsn
```

(`flux/apps/backend/base/deployment.yaml`; no `SERVICE_VERSION`: the backend reports the version baked
into its image.)

## Verification

### 1. Check OTel Collector

```bash
# No export errors
kubectl -n observability logs -l app.kubernetes.io/name=opentelemetry-collector --tail=100 | grep -i -E 'error|dropp'
```

### 2. Check Backend Application

```bash
# Port forward to backend
kubectl -n backend port-forward svc/backend 8080:8080

# Generate some traffic
curl http://localhost:8080/
curl http://localhost:8080/version
curl http://localhost:8080/delay/2
```

### 3. View in Uptrace Cloud

1. Go to https://app.uptrace.dev
2. Select your project
3. Navigate to **Traces** to see request flows
4. Navigate to **Metrics** to see application metrics
5. Navigate to **Logs** to see structured logs

**What to Look For:**
- Trace spans for HTTP requests (method, path, duration, status)
- Metrics from Prometheus scraping
- Log entries from backend application
- Automatic correlation between traces, metrics, and logs

## Telemetry Types

### Traces
- **HTTP Requests**: Method, path, status, duration
- **Span Attributes**: Custom attributes from instrumentation
- **Error Tracking**: Failed requests with stack traces

### Metrics
- **Application Metrics**: From `/metrics` endpoint (Prometheus format)
  - `app_http_requests_total`
  - `app_http_request_duration_seconds`
  - `app_http_in_flight_requests`
- **Runtime Metrics**: Go runtime statistics

### Logs
- **Structured Logs**: JSON-formatted application logs
- **Container Logs**: From `/var/log/pods`
- **Correlation**: Logs linked to traces via trace ID

## Troubleshooting

### No Data in Uptrace Cloud

1. **Check DSN Secret**:
   ```bash
   # The key is there and holds an https:// DSN - the value itself is never printed;
   # a decryption error, a missing key or a malformed value exits nonzero
   dsn=$(sops -d --extract '["stringData"]["uptrace-dsn"]' flux/secrets/develop/backend-secrets.yaml) \
     && case "$dsn" in https://*) echo "uptrace-dsn: set" ;; *) echo "uptrace-dsn: not an https:// DSN" >&2; false ;; esac
   unset dsn
   ```

2. **Check OTel Collector Logs**:
   ```bash
   kubectl -n observability logs -l app.kubernetes.io/name=opentelemetry-collector --tail=200
   ```

   Look for errors like:
   - `Exporting failed. Dropping data.`
   - `authentication failed`
   - `context deadline exceeded`

3. **Check Backend Logs**:
   ```bash
   kubectl -n develop logs -l app=backend --tail=100
   ```

   Should see `OpenTelemetry initialized: service=backend version=... env=...`; with no DSN,
   `OpenTelemetry running without Uptrace export: UPTRACE_DSN is not set`; export errors start with
   `OpenTelemetry error:`.

### OTel Collector Not Starting

```bash
# Check pod status
kubectl -n observability describe pod -l app.kubernetes.io/name=opentelemetry-collector
flux get helmreleases -n flux-system | grep otel

# Common issues:
# - Flux cannot substitute ${uptrace_dsn}: cluster-secrets is missing (Terraform writes it)
# - an invalid collector config: the pod logs name the component
# - Permission denied: RBAC not configured
```

### Backend Not Sending Telemetry

1. **Check Environment Variables** (names only - the DSN is a secret):
   ```bash
   kubectl -n develop exec deploy/backend -- env | grep -E 'OTEL|UPTRACE' | cut -d= -f1
   ```

2. **Check that Uptrace is reachable** from the backend's namespace (NetworkPolicy egress):
   ```bash
   scripts/lab-pod.sh -n develop -i curlimages/curl:8.22.0 -l app=backend -- curl -sS -o /dev/null -w '%{http_code}\n' https://api.uptrace.dev
   ```

## Development Workflow

### Local Development

For local development without Kubernetes:

```bash
# Export DSN
export UPTRACE_DSN="https://YOUR-TOKEN@api.uptrace.dev?grpc=4317"
export SERVICE_NAME="backend-local"
export DEPLOYMENT_ENVIRONMENT="local"

# Run backend
cd backend
go run cmd/api/main.go
```

The application will send telemetry directly to Uptrace Cloud (no local collector needed).

### Adding Custom Spans

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
)

func myFunction(ctx context.Context) {
    tracer := otel.Tracer("backend")
    ctx, span := tracer.Start(ctx, "myFunction")
    defer span.End()

    // Add attributes
    span.SetAttributes(
        attribute.String("user.id", "123"),
        attribute.Int("items.count", 5),
    )

    // Your code here...
}
```

### Adding Custom Metrics

```go
import (
    "go.opentelemetry.io/otel/metric"
)

// In your struct
var meter = otel.Meter("backend")
counter, _ := meter.Int64Counter("custom.events.total")

// Increment counter
counter.Add(ctx, 1, metric.WithAttributes(
    attribute.String("event.type", "user_signup"),
))
```

## Cost Considerations

Uptrace Cloud pricing is based on data volume:

- **Free Tier**: Limited data ingestion (check current limits)
- **Sampling**: Use head-based or tail-based sampling to reduce costs
- **Data Retention**: Adjust retention period for different environments

### Sampling Configuration

Edit `flux/infrastructure/observability/opentelemetry-collector/configmap.yaml`:

```yaml
processors:
  probabilistic_sampler:
    sampling_percentage: 10  # Keep 10% of traces
```

## References

- **Uptrace Documentation**: https://uptrace.dev/get/get-started.html
- **Uptrace Go SDK**: https://uptrace.dev/get/opentelemetry-go
- **OpenTelemetry Collector**: https://opentelemetry.io/docs/collector/
- **OTLP Specification**: https://opentelemetry.io/docs/specs/otlp/

## Next Steps

1. ✅ Uptrace Cloud account created
2. ✅ DSN secret encrypted with SOPS
3. ✅ OpenTelemetry Collector deployed
4. ✅ Backend instrumented with OTel SDK
5. 🔲 Create custom dashboards in Uptrace
6. 🔲 Set up alerting rules
7. 🔲 Add distributed tracing for external services
8. 🔲 Implement correlation between logs and traces
