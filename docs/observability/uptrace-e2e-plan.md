# Uptrace End-to-End Observability Plan (MVP Without OTel Collector)

## Scope and Decision

- This MVP does **not** run an in-cluster OpenTelemetry Collector.
- Frontend and backend export telemetry directly to Uptrace.
- Target flow: `frontend -> backend -> database`.

Note: The current repo has frontend+backend telemetry wiring already; database tracing/logging needs to be added.

## Current Code Wiring (As Of 2026-02-16)

Frontend:
- OTel web SDK setup: `frontend/src/services/telemetry.js`
- Auto HTTP/browser instrumentation: `FetchInstrumentation`, `XMLHttpRequestInstrumentation`, `DocumentLoadInstrumentation`, `UserInteractionInstrumentation`
- Manual UI spans (dashboard/chaos/api explorer): `frontend/src/stores/backend.js`, `frontend/src/views/ApiExplorerView.vue`, `frontend/src/views/ChaosView.vue`

Backend:
- OTel + Uptrace init: `backend/pkg/telemetry/telemetry.go`
- HTTP server instrumentation middleware: `backend/pkg/telemetry/middleware.go`
- Correlated request logs via context-aware logger: `backend/pkg/server/server.go`, `backend/pkg/logger/logger.go`

Current gaps:
- explicit backend OTLP log export pipeline to Uptrace Logs endpoint
- database layer instrumentation (no DB spans yet)
- incident runbook with concrete query set

## Configuration Reference

Frontend runtime:
- `VITE_UPTRACE_DSN` (preferred for direct Uptrace export)
- fallback trace endpoint: `VITE_OTEL_COLLECTOR_URL` (default local OTLP URL)

Backend runtime:
- `UPTRACE_DSN`
- `SERVICE_NAME`
- `SERVICE_VERSION`
- `DEPLOYMENT_ENVIRONMENT`

If `UPTRACE_DSN` is missing, backend telemetry runs without Uptrace export and logs a clear startup message.

## Architecture Target

1. Frontend (browser)
- Web traces exported via OTLP HTTP to Uptrace.
- Trace context headers (`traceparent`, `tracestate`, `baggage`) propagated to backend API calls.

2. Backend (Go API)
- Traces exported to Uptrace.
- Metrics exported via OTLP metric exporter to Uptrace.
- Logs correlated with trace/span IDs and exported to Uptrace Logs.

3. Database access layer (Go)
- DB calls wrapped with OpenTelemetry instrumentation.
- Spans include DB system, statement category, latency, and error metadata.

## Phase A: Baseline and Config Contract

Deliverables:
- Standardize environment variables for both services:
  - `UPTRACE_DSN`
  - `SERVICE_NAME`
  - `SERVICE_VERSION`
  - `DEPLOYMENT_ENVIRONMENT`
- Document secure secret injection path in Flux for:
  - backend DSN / headers
  - frontend runtime DSN value

Acceptance:
- Both services boot with explicit telemetry config.
- No hardcoded DSN/token in source code.

## Phase B: Frontend Telemetry Hardening

Deliverables:
- Keep OTLP trace export to Uptrace endpoint.
- Ensure CORS propagation list includes deployed backend hosts.
- Add manual spans around key UX flows:
  - dashboard refresh
  - chaos actions
  - API explorer request
- Add error capture attributes for failed API calls.

Acceptance:
- In Uptrace, each user action creates parent spans with child HTTP spans.
- Failed API calls are visible with status and route attributes.

## Phase C: Backend Traces + Metrics + Logs

Deliverables:
- Keep HTTP middleware instrumentation for inbound requests.
- Add outbound instrumentation for any external clients (if introduced).
- Add OTLP metrics export to Uptrace (request rate, duration, errors).
- Add OpenTelemetry log pipeline and trace correlation:
  - include `trace_id` and `span_id` in structured logs
  - export logs to Uptrace Logs endpoint

Acceptance:
- Uptrace shows backend traces, metrics, and logs under one service identity.
- From a backend span, related logs are discoverable by trace ID.

## Phase D: Context Propagation End-to-End

Deliverables:
- Explicitly configure W3C Trace Context + baggage propagators on backend.
- Verify frontend sends propagation headers and backend extracts them.
- Add synthetic check script for propagation:
  - call backend endpoint with known trace headers
  - verify child span linkage in Uptrace

Acceptance:
- Single trace graph contains browser span parent and backend child spans.
- No orphan backend spans for normal frontend traffic.

## Phase E: Database Tracing (frontend -> backend -> database)

Deliverables:
- Introduce DB instrumentation in backend data layer (when DB is added).
- Use one of:
  - `otelsql` instrumentation for `database/sql`, or
  - ORM-specific OTel instrumentation.
- Add semantic attributes:
  - `db.system`, `db.name`, operation type (`SELECT`, `INSERT`, etc.)
- Record DB errors on spans and log with trace correlation.

Acceptance:
- Uptrace trace waterfall includes DB spans under backend request span.
- Slow query and error cases are visible in traces and correlated logs.

## Phase F: Incident Debug Runbook

Deliverables:
- One production-like incident scenario documented:
  - symptom: increased p95 latency + sporadic 5xx
  - workflow: metrics -> trace drill-down -> logs -> rollback decision
- Add copy/paste query set:
  - latency and error metrics
  - trace filters by route/status
  - log filters by trace_id and severity

Acceptance:
- On-call can complete diagnosis path in <= 15 minutes in staging.

## Immediate Verification Scenario (Frontend -> Backend Crash)

Goal:
- Trigger backend crash from frontend.
- Observe a single trace chain from browser span to backend span.
- Confirm correlated backend logs contain `trace_id`.
- Confirm span contains log-like events (`request.log`, `panic.log`).

Steps:
1. Open frontend Chaos page and click **Trigger Panic**.
2. Copy the `trace_id` returned in UI message.
3. In Uptrace, search by this trace ID and open trace waterfall.
4. Verify:
   - frontend manual span `ui.chaos.trigger_panic`
   - backend HTTP span for `GET /panic`
   - span events `request.log` and `panic.log`
5. In backend pod logs, filter by the same `trace_id` and confirm matching error log.

## Implementation Order (Recommended)

1. Phase A + B (frontend stable trace export and action spans)
2. Phase C (backend metric/log completion)
3. Phase D (explicit propagation verification)
4. Phase E (DB instrumentation once DB layer exists)
5. Phase F (incident runbook and dry-run)

## Risks and Mitigations

- Risk: high telemetry volume/cost.
  - Mitigation: sampling policy per env (`develop` high, `production` controlled).
- Risk: sensitive data in spans/logs.
  - Mitigation: attribute allowlist + payload redaction rules.
- Risk: missing DB layer today.
  - Mitigation: define DB instrumentation contract now; implement once DB is introduced.
