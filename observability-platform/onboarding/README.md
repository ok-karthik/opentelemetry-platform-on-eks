# App Team Onboarding & Instrumentation

This directory consolidates the onboarding process, the contract between app and platform teams, and the language-specific instrumentation patterns.

## Contents

- [service-onboarding-contract.md](./service-onboarding-contract.md): The app-team/platform-team contract for metadata, SLOs, routing, dashboards, and alerts.
- [instrumentation-tiers-and-ebpf.md](./instrumentation-tiers-and-ebpf.md): Deep dive into the 4 levels of instrumentation (eBPF, auto-instrumentation, SDK, commercial tools), blind spots, and how to correlate them.
- [instrumentation-manifests/all-runtimes-instrumentation.yaml](./instrumentation-manifests/all-runtimes-instrumentation.yaml): OTel Operator multi-language auto-instrumentation template.

## Onboarding Model

The platform team owns the charts and templates. App teams only manage a small values file in their repo:

```text
app repo values -> platform chart -> Instrumentation, env vars, dashboards, alerts
```

### Self-Service App Team Values Snippet

App teams declare their service identity and SLOs in a simple values file (`observability-values.yaml`):

```yaml
serviceName: "product-info-service"
serviceNamespace: "catalog"
serviceVersion: "1.0.0"
environment: "production"
ownerTeam: "catalog-platform"
tenantId: "catalog"
language: "python"
slackChannel: "#alerts-catalog"

instrumentation:
  mode: "operator"
  annotation: "instrumentation.opentelemetry.io/inject-python"
  instrumentationRef: "default-instrumentation"

alerts:
  enabled: true
  latencyP99Ms: 750
  errorRatePercentage: 5
```

## Instrumentation Templates

The `instrumentation-manifests` contain platform-owned defaults for the OpenTelemetry Operator. Application teams opt in by adding the matching annotation (`instrumentation.opentelemetry.io/inject-<language>: "default-instrumentation"`) to their workload pod template.

Go is documented separately in [go-sdk-template.md](./instrumentation-manifests/go-sdk-template.md) because Go uses build-time SDK setup instead of runtime injection.

