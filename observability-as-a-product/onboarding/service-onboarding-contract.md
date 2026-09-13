# Service Onboarding Contract

This is the contract between application teams and the observability platform.

The goal is to keep app-team onboarding small and GitOps-friendly while the platform team keeps control of routing, sampling, cost, and backend integration.

## Ownership Boundary

App teams own telemetry intent and service metadata.

Platform teams own telemetry transport, policy, cost control, routing, and backend integration.

## What App Teams Provide

Every service must declare the following OpenTelemetry resource attributes:

```text
service.name
service.namespace
service.version
deployment.environment
team
tenant.id
```

Recommended Kubernetes labels:

```text
app.kubernetes.io/name
app.kubernetes.io/part-of
app.kubernetes.io/version
app.kubernetes.io/managed-by
platform.observability/team
platform.observability/tenant
platform.observability/environment
```

Minimum app-team GitOps values:

```yaml
serviceName: checkout-api
serviceNamespace: payments
serviceVersion: 1.2.3
environment: prod
ownerTeam: payments-platform
tenantId: payments
language: java
slackChannel: "#alerts-payments"

dashboards:
  enabled: true
  template: java-service

alerts:
  enabled: true
  latencyP99Ms: 500
  errorRatePercentage: 5
```

## What The Platform Provides

The platform provides:

- Workload-cluster OTel Collector DaemonSet baseline.
- Regional gateway endpoint discovery.
- Language-specific instrumentation templates.
- Central gateway filtering, transformation, batching, routing, and tail sampling.
- Golden signal dashboards.
- Standard alert rules.
- Alert labels and notification routing.
- Backend exporters and credentials.

## Supported Language Patterns

| Language | Recommended pattern |
| --- | --- |
| Python | OTel Operator auto-instrumentation |
| Java | OTel Operator auto-instrumentation |
| Node.js | OTel Operator auto-instrumentation |
| .NET | OTel Operator auto-instrumentation |
| Go | Shared SDK bootstrap/helper package (`telemetry.go`) |
| Any / Unmodified | Zero-Code eBPF DaemonSet (OBI kernel-level HTTP RED metrics & traces) |

Go services should use a small internal telemetry package or copy the SDK bootstrap pattern from `workloads/golang-app/telemetry.go`. Compiled services without SDKs can rely on the node-level eBPF (OBI) probe automatically.

## Routing Contract

The platform gateway routes telemetry using resource attributes, especially:

```text
tenant.id
service.namespace
deployment.environment
cloud.region
k8s.namespace.name
team
```

App repositories should not contain backend endpoint logic for Tempo, Loki, Mimir, Datadog, or other vendors. They should only declare ownership and service identity.

## Default Alert Contract

Default alerts should exist for:

- High error rate.
- High p99 latency.
- Low availability or missing traffic.
- Saturation signals when available.

Alerts must include:

```text
service
team
tenant
environment
severity
slack_channel
runbook_url
```

## Runbook Contract

Each production service should provide a runbook URL. If no custom runbook is supplied, the platform chart can generate a standard path:

```text
https://runbooks.example.internal/<serviceName>/<alertName>
```

## Onboarding Review Checklist

- Service has stable `service.name`.
- Service has `tenant.id` or `service.namespace`.
- Service declares `deployment.environment`.
- Service has an owner team and alert channel.
- Language instrumentation template is selected.
- Dashboard template is selected.
- Latency and error thresholds are set.
- Telemetry is routed through workload collector, not directly to backends.
