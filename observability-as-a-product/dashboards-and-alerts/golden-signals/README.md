# Golden Signals Templates

Contains standardized dashboard templates based on SRE's Four Golden Signals (Latency, Traffic, Errors, Saturation).

* **Go Service**: [go-service-dashboard.json](go-service-dashboard.json)
* **Python Service**: [python-service-dashboard.json](python-service-dashboard.json)

## How This Scales

Use these as baseline dashboards generated per service from standard OpenTelemetry resource attributes:

- `service.name`
- `service.namespace` or owning team
- `deployment.environment`
- `service.version`

In a 1000+ service estate, the goal is not hand-built dashboards. The platform publishes a small number of golden templates, and teams get service-specific dashboards by setting consistent labels and values in Git.

## Implementation

1. Local/demo: load the JSON dashboards into Grafana through ConfigMaps or provisioning.
2. Production Kubernetes: wrap the dashboards as `GrafanaDashboard` CRDs through Helm or GitOps.
3. Enterprise SaaS: translate the same golden signal queries into Datadog/Dynatrace dashboard modules.
