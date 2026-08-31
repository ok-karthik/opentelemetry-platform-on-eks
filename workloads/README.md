# Workloads & Microservices

This directory contains the application-team-owned microservices and the node-local OpenTelemetry Collector DaemonSet.

---

## Directory Structure

```text
workloads/
├── golang-app/                     # Go Product Service (Level 3 Programmatic SDK)
│   ├── main.go                     # HTTP API endpoints (/products, /health)
│   ├── telemetry.go                # Tracer/Meter bootstrap with resource attributes & GOMEMLIMIT
│   ├── Dockerfile                  # Multi-stage scratch build container
│   ├── golang-product-service.yaml # Deployment & ClusterIP Service
│   └── app-ingress.yaml            # Internet-facing AWS ALB Ingress
│
├── python-app/                     # Python Product Info Service (Level 2 Auto-Instrumentation)
│   ├── main.py                     # Flask microservice
│   ├── requirements.txt            # Dependencies
│   ├── Dockerfile                  # Container definition
│   ├── python-product-info-service.yaml # Deployment with inject-python annotations
│   └── otel-instrumentation-python.yaml # OpenTelemetry Operator Instrumentation CR
│
├── samples/                        # Benchmark & Demonstration Workloads
│   ├── uninstrumented-nginx.yaml   # Level 1 eBPF & Filelog demo (100% Uninstrumented Nginx + LoadGen)
│   └── bookinfo.yaml               # Polyglot Bookinfo microservices (Runs WITHOUT Istio/Envoy)
│
└── otel-collector-daemonset.yaml   # Tier 1 Edge Node DaemonSet Collector + OBI eBPF (HostNetwork Downward API)
```

---

## Key Telemetry Patterns

1. **Node-Local Agent Target (`status.hostIP`):**
   - Workloads target their node's local agent via `status.hostIP:4317` (not the ClusterIP Service). This ensures the `k8sattributes` processor accurately enriches telemetry with local pod metadata without needing every collector to watch every pod in the cluster.
2. **Runtime Auto-Instrumentation (Python):**
   - Injected via `instrumentation.opentelemetry.io/inject-python: "python-instrumentation"`. Automatically instruments HTTP requests, exceptions, and outbound calls without manual code modifications.
3. **Explicit SDK Bootstrap (Go):**
   - Uses `go.opentelemetry.io/otel` with `resource.WithFromEnv()` to ensure standard semantic attributes (`service.name`, `service.version`, `deployment.environment`, `tenant.id`) are propagated to traces, metrics, and logs.
