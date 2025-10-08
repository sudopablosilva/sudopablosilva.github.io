# Multi-Service Pipeline Architecture

## System Overview

```
┌─────────┐    HTTP     ┌───────────┐    SQS      ┌───────────┐    SQS      ┌───────────┐
│ Client  │ ──────────► │ Service 1 │ ──────────► │ Service 2 │ ──────────► │ Service 3 │
│         │             │   :8080   │             │   :8081   │             │   :8082   │
└─────────┘             └───────────┘             └───────────┘             └───────────┘
                               │                         │                         │
                               │                         │                         │
                               ▼                         ▼                         ▼
                        ┌─────────────────────────────────────────────────────────────┐
                        │                 Datadog Agent                               │
                        │  • Distributed Traces (APM)                               │
                        │  • Custom Metrics (DogStatsD)                             │
                        │  • Structured Logs                                        │
                        └─────────────────────────────────────────────────────────────┘
                                                   │
                                                   ▼
                                          ┌─────────────────┐
                                          │  Datadog Cloud  │
                                          │  • APM Dashboard│
                                          │  • Log Search   │
                                          │  • Metrics      │
                                          └─────────────────┘
```

## Components

### Service 1 (Entry Point)
- **Port**: 8080
- **Role**: Receives HTTP requests, processes them, sends to Service 2
- **Queue**: `service1-to-service2`
- **Traces**: Creates root spans for incoming requests

### Service 2 (Middle Service)
- **Port**: 8081
- **Role**: Processes messages from Service 1, forwards to Service 3
- **Queue**: `service2-to-service3`
- **Traces**: Continues trace context from Service 1

### Service 3 (Final Service)
- **Port**: 8082
- **Role**: Final processing of the pipeline
- **Traces**: Completes the distributed trace

## SQS Queues

1. **service1-to-service2**: Messages from Service 1 → Service 2
2. **service2-to-service3**: Messages from Service 2 → Service 3

## Datadog v2 Implementation

### Tracing Setup
All services use Datadog v2 tracing library:

```go
// v2 imports
import (
    httptrace "github.com/DataDog/dd-trace-go/contrib/net/http/v2"
    "github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"
)

// v2 initialization
tracer.Start(
    tracer.WithService("service-name"),
    tracer.WithEnv("pipeline"),
    tracer.WithServiceVersion("1.1.0"),
)
```

### Orchestrion Integration
**Orchestrion** provides automatic instrumentation for:
- HTTP requests/responses
- SQS message processing
- Database queries (when applicable)
- Third-party library calls

Enabled via dependency in `go.mod`:
```go
require github.com/DataDog/orchestrion v1.5.0
```

### Trace Propagation
SQS trace context propagation:

```go
// Inject trace context into SQS message attributes
carrier := make(map[string]string)
tracer.Inject(span.Context(), tracer.TextMapCarrier(carrier))

// Extract trace context from SQS message attributes
spanCtx, _ := tracer.Extract(tracer.TextMapCarrier(carrier))
span := tracer.StartSpan("operation", tracer.ChildOf(spanCtx))
```

## Observability Features

- **Distributed Tracing**: End-to-end request tracking across all services
- **Correlation IDs**: Business-level request correlation
- **Structured Logging**: JSON logs with trace correlation
- **Custom Metrics**: Processing time, message counts, error rates
- **Automatic Instrumentation**: Via Orchestrion
- **SQS Trace Continuity**: Manual trace propagation through message attributes

## Migration from v1 to v2

Key changes made:

| v1 API | v2 API |
|--------|--------|
| `gopkg.in/DataDog/dd-trace-go.v1/*` | `github.com/DataDog/dd-trace-go/*/v2` |
| `tracer.WithServiceName()` | `tracer.WithService()` |
| `tracer.WithGlobalTag("env", "val")` | `tracer.WithEnv("val")` |
| `tracer.WithGlobalTag("version", "val")` | `tracer.WithServiceVersion("val")` |
| `var span tracer.Span` | `var span *tracer.Span` |