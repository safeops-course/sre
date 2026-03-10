# Distributed Tracing with OpenTelemetry

Complete guide for end-to-end distributed tracing from browser to backend using OpenTelemetry and Uptrace Cloud.

## Overview

Our distributed tracing implementation provides full request visibility across:
- **Frontend (Browser)**: Vue 3 SPA with OpenTelemetry Web SDK
- **Backend (Go)**: HTTP API with OpenTelemetry SDK
- **OpenTelemetry Collector**: Aggregates and forwards traces
- **Uptrace Cloud**: Visualizes distributed traces

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Browser                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Frontend (Vue 3 + OTel Web SDK)                           │ │
│  │  - User clicks "Get Version"                               │ │
│  │  - OTel creates span: trace_id=abc123, span_id=xyz         │ │
│  │  - HTTP GET /version                                       │ │
│  │  - Header: traceparent: 00-abc123-xyz-01                  │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────┼───────────────────┘
                                              │
                                              ▼
                                    ┌──────────────────┐
                                    │ OTel Collector   │
                                    │ :4318 (HTTP)     │
                                    └──────────────────┘
                                              │
┌─────────────────────────────────────────────┼───────────────────┐
│                    Kubernetes Cluster       │                   │
│  ┌────────────────────────────────────────┐ │                   │
│  │  Backend (Go + OTel SDK)               │ │                   │
│  │  - Receives request with traceparent   │ │                   │
│  │  - Extracts trace_id=abc123, parent=xyz│ │                   │
│  │  - Creates child span: span_id=def     │ │                   │
│  │  - Processes /version handler          │ │                   │
│  └────────────────────────────────────────┘ │                   │
│                                              │                   │
│                                              ▼                   │
│                                    ┌──────────────────┐         │
│                                    │ OTel Collector   │         │
│                                    │ :4317 (gRPC)     │         │
│                                    └──────────────────┘         │
└─────────────────────────────────────────────┼───────────────────┘
                                              │
                                              ▼
                                    ┌──────────────────┐
                                    │ Uptrace Cloud ☁️  │
                                    │                  │
                                    │ Trace: abc123    │
                                    │  ├─ Frontend     │
                                    │  │  └─ HTTP GET  │
                                    │  └─ Backend      │
                                    │     └─ Handler   │
                                    └──────────────────┘
```

## Frontend Instrumentation

### OpenTelemetry Web SDK Setup

**Dependencies** (`frontend/package.json`):
```json
{
  "dependencies": {
    "@opentelemetry/api": "^1.9.0",
    "@opentelemetry/sdk-trace-web": "^2.1.0",
    "@opentelemetry/exporter-trace-otlp-http": "^0.206.0",
    "@opentelemetry/instrumentation": "^0.206.0",
    "@opentelemetry/instrumentation-fetch": "^0.206.0",
    "@opentelemetry/instrumentation-xml-http-request": "^0.206.0",
    "@opentelemetry/instrumentation-document-load": "^0.52.0",
    "@opentelemetry/instrumentation-user-interaction": "^0.51.0",
    "@opentelemetry/resources": "^2.1.0",
    "@opentelemetry/semantic-conventions": "^1.37.0"
  }
}
```

**Telemetry Service** (`frontend/src/services/telemetry.js`):
```javascript
import { WebTracerProvider } from '@opentelemetry/sdk-trace-web'
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http'
import { Resource } from '@opentelemetry/resources'
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace-web'
import { registerInstrumentations } from '@opentelemetry/instrumentation'
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch'

export function initTelemetry() {
  const config = {
    serviceName: 'frontend',
    serviceVersion: '1.0.0',
    collectorUrl: window.__ENV__?.VITE_OTEL_COLLECTOR_URL ||
                  'http://localhost:4318/v1/traces',
  }

  const resource = new Resource({
    'service.name': config.serviceName,
    'service.version': config.serviceVersion,
  })

  const provider = new WebTracerProvider({ resource })

  const exporter = new OTLPTraceExporter({
    url: config.collectorUrl,
  })

  provider.addSpanProcessor(new BatchSpanProcessor(exporter))
  provider.register()

  registerInstrumentations({
    instrumentations: [
      new FetchInstrumentation({
        propagateTraceHeaderCorsUrls: [
          /localhost/,
          /\.svc\.cluster\.local$/,
        ],
      }),
    ],
  })
}
```

**Initialization** (`frontend/src/main.js`):
```javascript
import { initTelemetry } from './services/telemetry'

// Initialize before Vue app
initTelemetry()

const app = createApp(App)
app.mount('#app')
```

### Auto-Instrumentation Features

**1. HTTP Requests (Fetch/Axios)**
- Automatically creates spans for all HTTP requests
- Injects `traceparent` header for trace propagation
- Records HTTP method, URL, status code
- Tracks request/response timing

**2. Document Load**
- Page load performance metrics
- Resource timing
- DOM content loaded
- First contentful paint

**3. User Interactions**
- Click events with target element
- Form submissions
- Custom event names

**Example Trace Output:**
```
Span: GET /version
├─ trace_id: a1b2c3d4e5f6g7h8
├─ span_id: xyz123
├─ attributes:
│  ├─ http.method: GET
│  ├─ http.url: http://backend.frontend.svc.cluster.local:8080/version
│  ├─ http.status_code: 200
│  └─ http.response_content_length: 156
└─ duration: 45ms
```

## Backend Instrumentation

### OpenTelemetry Go SDK Setup

**Dependencies** (`backend/go.mod`):
```go
require (
    github.com/uptrace/uptrace-go v1.38.0
    go.opentelemetry.io/otel v1.38.0
    go.opentelemetry.io/otel/sdk v1.38.0
    go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.63.0
)
```

**Telemetry Initialization** (`backend/pkg/telemetry/telemetry.go`):
```go
package telemetry

import (
    "context"
    "github.com/uptrace/uptrace-go/uptrace"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/trace"
)

func Init(ctx context.Context) func() {
    uptrace.ConfigureOpentelemetry(
        uptrace.WithServiceName("backend"),
        uptrace.WithServiceVersion("v1.0.0"),
        uptrace.WithDeploymentEnvironment("development"),
    )

    return func() {
        uptrace.Shutdown(ctx)
    }
}

func Tracer() trace.Tracer {
    return otel.Tracer("backend")
}
```

**HTTP Middleware** (`backend/pkg/telemetry/middleware.go`):
```go
package telemetry

import (
    "net/http"
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func HTTPMiddleware(next http.Handler) http.Handler {
    return otelhttp.NewHandler(next, "backend",
        otelhttp.WithSpanNameFormatter(func(operation string, r *http.Request) string {
            return r.Method + " " + r.URL.Path
        }),
    )
}
```

**CORS for Trace Headers** (`backend/pkg/server/server.go`):
```go
func (s *Server) corsMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Access-Control-Allow-Origin", "*")
        w.Header().Set("Access-Control-Allow-Headers", "traceparent, tracestate")
        w.Header().Set("Access-Control-Expose-Headers", "traceparent, tracestate")

        if r.Method == "OPTIONS" {
            w.WriteHeader(http.StatusOK)
            return
        }

        next.ServeHTTP(w, r)
    })
}
```

### Custom Instrumentation

**Creating Custom Spans:**
```go
import "github.com/safeops-course/sre/backend/pkg/telemetry"

func processOrder(ctx context.Context, orderID string) error {
    ctx, span := telemetry.StartSpan(ctx, "processOrder")
    defer span.End()

    telemetry.SetAttributes(ctx,
        attribute.String("order.id", orderID),
        attribute.Int("order.items", 5),
    )

    // Business logic here...

    telemetry.AddEvent(ctx, "order.processed")
    return nil
}
```

**Error Recording:**
```go
func handleRequest(ctx context.Context) error {
    ctx, span := telemetry.StartSpan(ctx, "handleRequest")
    defer span.End()

    if err := doSomething(); err != nil {
        telemetry.RecordError(ctx, err)
        return err
    }

    return nil
}
```

## Trace Propagation

### W3C Trace Context Standard

**traceparent Header Format:**
```
traceparent: 00-{trace-id}-{parent-span-id}-{trace-flags}

Example:
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
             │  └─ trace_id (32 hex chars)      │                └─ sampled flag
             │                                   └─ parent span_id (16 hex)
             └─ version (00)
```

**Propagation Flow:**

1. **Frontend generates trace:**
   ```javascript
   // OTel Web SDK automatically creates:
   trace_id: 4bf92f3577b34da6a3ce929d0e0e4736
   span_id: 00f067aa0ba902b7
   ```

2. **HTTP request with header:**
   ```
   GET /version HTTP/1.1
   traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
   ```

3. **Backend extracts context:**
   ```go
   // otelhttp middleware automatically:
   // - Extracts trace_id and parent span_id
   // - Creates child span with same trace_id
   // - Sets parent relationship
   ```

4. **Result in Uptrace:**
   ```
   Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736
   ├─ Frontend: user.click (span: 00f067aa0ba902b7)
   │  └─ Frontend: HTTP GET (span: a1b2c3d4e5f6g7h8)
   │     └─ Backend: GET /version (span: 0123456789abcdef)
   │        └─ Backend: database.query (span: fedcba9876543210)
   ```

## Deployment Configuration

### Frontend Deployment

**Kubernetes Manifest** (`flux/apps/frontend/base/deployment.yaml`):
```yaml
env:
  - name: VITE_API_URL
    value: "http://backend.frontend.svc.cluster.local:8080"
  - name: VITE_OTEL_COLLECTOR_URL
    value: "http://otel-collector.observability.svc.cluster.local:4318/v1/traces"
  - name: ENVIRONMENT
    value: "development"
```

**Runtime Config Generation** (Dockerfile):
```dockerfile
RUN echo '#!/bin/sh' > /docker-entrypoint.d/40-generate-env-config.sh && \
    echo 'cat <<EOF > /usr/share/nginx/html/config.js' >> /docker-entrypoint.d/40-generate-env-config.sh && \
    echo 'window.__ENV__ = {' >> /docker-entrypoint.d/40-generate-env-config.sh && \
    echo '  VITE_OTEL_COLLECTOR_URL: "${VITE_OTEL_COLLECTOR_URL}"' >> /docker-entrypoint.d/40-generate-env-config.sh && \
    echo '};' >> /docker-entrypoint.d/40-generate-env-config.sh && \
    echo 'EOF' >> /docker-entrypoint.d/40-generate-env-config.sh
```

### Backend Deployment

**Kubernetes Manifest** (`flux/apps/backend/base/deployment.yaml`):
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

## Viewing Traces in Uptrace Cloud

### 1. Access Uptrace Dashboard

Visit: https://app.uptrace.dev

Navigate to your project → Traces

### 2. Trace Visualization

**Flame Graph View:**
```
Timeline (horizontal axis = time)
─────────────────────────────────────────────────────────────
│ Frontend: document.load                    │ 250ms
│  ├─ Frontend: fetch /version   │ 45ms
│  │  └─ Backend: GET /version  │ 40ms
│  │     ├─ Backend: parse request │ 2ms
│  │     ├─ Backend: process       │ 35ms
│  │     └─ Backend: format response │ 3ms
─────────────────────────────────────────────────────────────
```

**Trace Details:**
- **Trace ID**: Full distributed trace identifier
- **Duration**: Total request time
- **Spans**: Individual operations
- **Attributes**: Custom metadata
- **Events**: Logged events within spans
- **Errors**: Recorded exceptions

### 3. Filtering Traces

**By Service:**
```
service.name = "frontend"
service.name = "backend"
```

**By HTTP Status:**
```
http.status_code >= 500  # Server errors
http.status_code = 404   # Not found
```

**By Duration:**
```
duration > 1s            # Slow requests
duration > 100ms         # Moderate latency
```

**By Custom Attribute:**
```
order.id = "12345"
user.id = "abc"
```

### 4. Common Queries

**Find slow requests:**
```
service.name = "backend" AND duration > 500ms
```

**Find failed requests:**
```
http.status_code >= 500
```

**Find requests from specific user:**
```
user.id = "user123"
```

**Find database queries:**
```
span.name LIKE "%database%"
```

## Performance Optimization

### Sampling Configuration

**Frontend (reduce trace volume):**
```javascript
import { ParentBasedSampler, TraceIdRatioBasedSampler } from '@opentelemetry/sdk-trace-web'

const provider = new WebTracerProvider({
  resource,
  sampler: new ParentBasedSampler({
    root: new TraceIdRatioBasedSampler(0.1), // Sample 10% of traces
  }),
})
```

**Backend (tail-based sampling):**
```yaml
# OTel Collector config
processors:
  tail_sampling:
    decision_wait: 10s
    policies:
      - name: error-traces
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow-traces
        type: latency
        latency: { threshold_ms: 1000 }
      - name: sample-10-percent
        type: probabilistic
        probabilistic: { sampling_percentage: 10 }
```

### Batch Processing

**Frontend:**
```javascript
provider.addSpanProcessor(new BatchSpanProcessor(exporter, {
  maxQueueSize: 100,
  maxExportBatchSize: 10,
  scheduledDelayMillis: 500,
}))
```

**Backend:**
Already configured via `uptrace.ConfigureOpentelemetry()`.

## Troubleshooting

### No Traces Appearing

**Check Frontend Console:**
```javascript
// Should see:
[Telemetry] Initializing OpenTelemetry...
[Telemetry] OpenTelemetry initialized successfully
```

**Check Network Tab:**
```
POST http://otel-collector.observability:4318/v1/traces
Status: 200 OK
```

**Check OTel Collector Logs:**
```bash
kubectl -n observability logs -l app=otel-collector --tail=100

# Should see:
2025-10-10T10:15:30.123Z info Traces received {"#spans": 5}
```

**Check Backend Logs:**
```bash
kubectl -n backend logs -l app=backend --tail=100

# Should see:
OpenTelemetry initialized: service=backend version=v1.0.0 env=development
```

### Traces Not Correlated

**Verify CORS Headers:**
```bash
curl -I -X OPTIONS http://backend:8080/version \
  -H "Origin: http://frontend:8080" \
  -H "Access-Control-Request-Headers: traceparent"

# Should include:
Access-Control-Allow-Headers: traceparent, tracestate
```

**Verify traceparent Header:**
```javascript
// In browser console:
fetch('http://backend:8080/version')
  .then(r => console.log(r.headers.get('traceparent')))

// Should output:
00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```

### High Cardinality Issues

**Problem:** Too many unique span names

**Solution:** Use span name formatter
```go
otelhttp.WithSpanNameFormatter(func(operation string, r *http.Request) string {
    // Instead of: GET /users/123/orders/456
    // Use: GET /users/{id}/orders/{id}
    return r.Method + " " + routePattern(r)
})
```

## Best Practices

### 1. Span Naming

**❌ Bad:**
```
span: http_request
span: database
span: process
```

**✅ Good:**
```
span: GET /api/users/{id}
span: database.users.select
span: order.process.payment
```

### 2. Attributes

**❌ Bad:**
```go
span.SetAttribute("data", fmt.Sprintf("%+v", complexObject))
```

**✅ Good:**
```go
span.SetAttributes(
    attribute.String("user.id", user.ID),
    attribute.Int("order.items.count", len(items)),
    attribute.String("payment.method", "credit_card"),
)
```

### 3. Error Handling

**❌ Bad:**
```go
if err != nil {
    return err
}
```

**✅ Good:**
```go
if err != nil {
    telemetry.RecordError(ctx, err)
    span.SetStatus(codes.Error, err.Error())
    return err
}
```

### 4. Sensitive Data

**❌ Never log:**
- Passwords
- API keys
- Credit card numbers
- PII (email, phone, SSN)

**✅ Use masked values:**
```go
span.SetAttributes(
    attribute.String("email", maskEmail(user.Email)), // "u***@example.com"
    attribute.String("card.last4", card.Last4),       // "4242"
)
```

## Example: Complete Trace

**User Story:** User clicks "Get Version" button

**1. Frontend Click:**
```
Span: user.interaction
├─ trace_id: abc123
├─ span_id: span001
├─ attributes:
│  ├─ event.type: click
│  └─ target.element: button#get-version
└─ duration: 1ms
```

**2. Frontend HTTP Request:**
```
Span: GET /version
├─ trace_id: abc123
├─ span_id: span002
├─ parent_id: span001
├─ attributes:
│  ├─ http.method: GET
│  ├─ http.url: http://backend:8080/version
│  └─ http.status_code: 200
└─ duration: 45ms
```

**3. Backend Handler:**
```
Span: GET /version
├─ trace_id: abc123
├─ span_id: span003
├─ parent_id: span002
├─ attributes:
│  ├─ http.method: GET
│  ├─ http.route: /version
│  └─ http.status_code: 200
└─ duration: 40ms
```

**Result in Uptrace:**
```
Trace ID: abc123 (Total: 46ms)
├─ [Frontend] user.interaction (1ms)
│  └─ [Frontend] GET /version (45ms)
│     └─ [Backend] GET /version (40ms)
```

## References

- **W3C Trace Context**: https://www.w3.org/TR/trace-context/
- **OpenTelemetry Docs**: https://opentelemetry.io/docs/
- **Uptrace Documentation**: https://uptrace.dev/get/get-started.html
- **OTel Web SDK**: https://opentelemetry.io/docs/languages/js/
- **OTel Go SDK**: https://uptrace.dev/get/opentelemetry-go

## Next Steps

1. ✅ Distributed tracing configured
2. 🔲 Add custom spans for business logic
3. 🔲 Configure sampling for production
4. 🔲 Create dashboards in Uptrace
5. 🔲 Set up alerts for slow traces
6. 🔲 Implement SLO tracking
