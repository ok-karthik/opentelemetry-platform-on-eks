# App Team Onboarding & Instrumentation

This directory consolidates the onboarding process, the contract between app and platform teams, and the language-specific instrumentation patterns.

## Contents

- [service-onboarding-contract.md](./service-onboarding-contract.md): The app-team/platform-team contract for metadata, SLOs, routing, dashboards, and alerts.
- [instrumentation-tiers-and-ebpf.md](./instrumentation-tiers-and-ebpf.md): Deep dive into the 4 levels of instrumentation (eBPF, auto-instrumentation, SDK, commercial tools), blind spots, and how to correlate them.
- **`values-examples/`**: Example values that an application team would keep in its own workload repository.
- **`instrumentation-manifests/`**: Language-specific OTel Operator templates and Go SDK patterns.

## Onboarding Model

The platform team owns the charts and templates. App teams only change their own values.

```text
app repo values -> platform chart -> Instrumentation, env vars, dashboards, alerts
```

Use these examples to explain self-service onboarding for many teams without platform tickets for every service.

## Instrumentation Templates

The `instrumentation-manifests` are platform-owned defaults for the OpenTelemetry Operator. Application teams opt in by adding the matching annotation to their workload pod template. The platform keeps the exporter endpoint, propagators, and default language settings consistent across clusters.

Go is intentionally documented separately because Go usually needs SDK setup at build time instead of runtime injection.
