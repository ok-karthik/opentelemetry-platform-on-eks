# Gateway Configuration & Pipeline Policies

This directory demonstrates central OTel Collector gateway policies, specifically how the platform team can enforce routing, multi-tenancy, and telemetry budgeting (cost control).

## Policies

* **Multi-tenant Routing**: [otel-gateway-multitenant.yaml](otel-gateway-multitenant.yaml)
* **Telemetry Budgeting (Tail Sampling)**: [otel-gateway-tail-sampling.yaml](otel-gateway-tail-sampling.yaml)

## Routing Inputs

The gateway can route by attributes that app teams already provide, keeping platform-owned collector config centralized while app teams only manage labels:
- `service.namespace`
- `deployment.environment`
- `cloud.region`
- `k8s.namespace.name`
- `team` or `tenant`

### Routing Use Cases
- Send production and non-production telemetry to different backends or retention tiers.
- Route regulated workloads to region-local storage.
- Give high-criticality services stricter sampling and retention.

## Telemetry Budgeting

Telemetry budgeting is how the platform keeps observability useful without letting cost grow linearly with traffic.
- Keep 100% of failed traces.
- Keep 100% of latency outliers.
- Sample healthy high-volume traffic.
- Drop health checks and other noisy low-value spans.
- Normalize or reject high-cardinality attributes before storage.

### Key Takeaways
At enterprise scale, sampling should be a platform default, not an app-by-app decision. Teams can request exceptions for critical flows, but the gateway enforces shared cost and reliability policy.
