# Dashboards & Alerts

This directory provides blueprints for managing dashboards and alert rules at scale, based on SRE's Four Golden Signals (Latency, Traffic, Errors, Saturation).

## Contents

- **`golden-signals/`**: Standardized Grafana dashboard JSONs (Go service, Python service, and OTel Collector Meta-Monitoring).
- **[META_MONITORING.md](./META_MONITORING.md)**: Deep-dive architecture and PromQL rules for monitoring the observability platform itself.
- **`helm-chart/`**: Platform-owned Helm templates demonstrating how to render dashboards and alerts from GitOps values.

## How This Scales

In a 1000+ service estate, the goal is not hand-built dashboards. The platform publishes a small number of golden templates, and teams get service-specific dashboards by setting consistent labels and values in Git.

Use these as baseline dashboards generated per service from standard OpenTelemetry resource attributes:
- `service.name`
- `service.namespace` or owning team
- `deployment.environment`
- `service.version`

## Recommended Model: Decentralized GitOps

For 1000+ services, use decentralized GitOps with platform-owned Helm templates:
1. App developers define Service Level Objectives (SLOs), targets, and alert thresholds in their application repository's `values.yaml`.
2. The platform chart renders dashboards (`GrafanaDashboard`) and alert rules (`PrometheusRule`) consistently.
3. Argo CD or Flux applies the generated resources.
4. Platform teams review the template once instead of reviewing every dashboard by hand.

This keeps onboarding self-service while preserving standard naming, labels, severity, and routing.

### Other Patterns
* **Centralized Infrastructure as Code (Terraform)**: Telemetry configs are managed centrally in a single IaC repository. Useful for SaaS setups (e.g., Datadog) but can introduce pull-request bottlenecks at scale.
* **Datadog Operator**: A middleground where developers define `DatadogMonitor` CRDs locally in the application repo, which the operator syncs to the Datadog API.
