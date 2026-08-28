# Go SDK Template

Go services normally use an SDK bootstrap package instead of OTel Operator runtime injection.

Minimum contract:

```text
OTEL_EXPORTER_OTLP_ENDPOINT=otel-collector-agent-collector.monitoring.svc.cluster.local:4317
OTEL_RESOURCE_ATTRIBUTES=service.name=<name>,service.namespace=<namespace>,service.version=<version>,deployment.environment=<env>,team=<team>,tenant.id=<tenant>
```

The demo implementation is:

```text
apps-workload-cluster-1/apps-src/golang-app/telemetry.go
```

For a real platform, publish an internal Go module such as:

```text
github.example.internal/platform/observability-go
```

That helper should initialize:

- OTLP trace exporter.
- OTLP metric exporter.
- W3C tracecontext and baggage propagation.
- Stable resource attributes from environment variables.
- Graceful shutdown and flush.
