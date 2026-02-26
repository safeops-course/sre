# Uptrace Cloud Integration

This guide covers the Uptrace Cloud integration for unified observability (logs, traces, and metrics).

> Current MVP note (2026-02-16): this repo uses **direct export to Uptrace** from frontend/backend and does **not** require an in-cluster OpenTelemetry Collector.  
> Execution plan: `docs/observability/uptrace-e2e-plan.md`.

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
│  ┌──────────────┐                                               │
│  │   Backend    │  OTLP/gRPC (traces, metrics, logs)            │
│  │ (Go + OTel)  │────────┐                                      │
│  └──────────────┘        │                                      │
│                          ▼                                      │
│                   ┌────────────────┐                            │
│                   │ OTel Collector │                            │
│                   │   (DaemonSet)  │                            │
│                   └────────────────┘                            │
│                          │                                      │
│                          │ OTLP/gRPC + DSN                      │
└──────────────────────────┼──────────────────────────────────────┘
                           │
                           ▼
                  ┌─────────────────┐
                  │ Uptrace Cloud ☁️ │
                  │ api.uptrace.dev  │
                  └─────────────────┘
```

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

### 2. Create Encrypted Secret

Use the SOPS helper script to create an encrypted secret:

```bash
# Copy the example secret
cp flux/secrets/develop/uptrace-secrets.yaml.example \
   flux/secrets/develop/uptrace-secrets.yaml

# Edit with SOPS (will encrypt on save)
sops flux/secrets/develop/uptrace-secrets.yaml

# Replace the DSN value with your actual token:
stringData:
  dsn: "https://YOUR-TOKEN@api.uptrace.dev?grpc=4317"

# Save and exit - SOPS will automatically encrypt
```

**IMPORTANT**: The secret is already referenced in:
- `flux/infrastructure/observability/opentelemetry-collector/daemonset.yaml` (OTel Collector)
- `flux/apps/backend/base/deployment.yaml` (Backend application)

### 3. Deploy OpenTelemetry Collector

The OpenTelemetry Collector is deployed as a DaemonSet (one pod per node):

```bash
# Apply Flux Kustomization (if not already bootstrapped)
kubectl apply -f flux/bootstrap/flux-system/infrastructure.yaml

# Verify deployment
kubectl -n observability get daemonset otel-collector
kubectl -n observability get pods -l app=otel-collector
kubectl -n observability logs -l app=otel-collector --tail=50
```

**OTel Collector Configuration:**
- **Receivers**: OTLP (gRPC + HTTP), Prometheus, File logs
- **Processors**: Memory limiter, batch, resource detection
- **Exporters**: Uptrace Cloud via OTLP

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
  - name: SERVICE_VERSION
    value: "v1.0.0"
  - name: DEPLOYMENT_ENVIRONMENT
    value: "development"
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector.observability.svc.cluster.local:4317"
  - name: UPTRACE_DSN
    valueFrom:
      secretKeyRef:
        name: uptrace-secrets
        key: dsn
```

## Verification

### 1. Check OTel Collector

```bash
# Check logs for successful export
kubectl -n observability logs -l app=otel-collector --tail=100 | grep -i uptrace

# Check metrics endpoint
kubectl -n observability port-forward svc/otel-collector 8888:8888
curl http://localhost:8888/metrics
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
   # Decrypt and verify secret
   sops -d flux/secrets/develop/uptrace-secrets.yaml
   ```

2. **Check OTel Collector Logs**:
   ```bash
   kubectl -n observability logs -l app=otel-collector --tail=200
   ```

   Look for errors like:
   - `failed to connect to api.uptrace.dev:4317`
   - `authentication failed`
   - `context deadline exceeded`

3. **Check Backend Logs**:
   ```bash
   kubectl -n backend logs -l app=backend --tail=100
   ```

   Should see:
   ```
   OpenTelemetry initialized: service=backend version=v1.0.0 env=development
   ```

### OTel Collector Not Starting

```bash
# Check pod status
kubectl -n observability describe pod -l app=otel-collector

# Common issues:
# - Secret not found: uptrace-secrets doesn't exist
# - ConfigMap error: otel-collector-config invalid YAML
# - Permission denied: RBAC not configured
```

### Backend Not Sending Telemetry

1. **Verify OTLP Endpoint**:
   ```bash
   # From within backend pod
   kubectl -n backend exec -it deploy/backend -- sh
   nc -zv otel-collector.observability.svc.cluster.local 4317
   ```

2. **Check Environment Variables**:
   ```bash
   kubectl -n backend exec deploy/backend -- env | grep -E 'OTEL|UPTRACE'
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
