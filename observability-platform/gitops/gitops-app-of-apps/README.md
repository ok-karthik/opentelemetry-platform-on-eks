# GitOps App Of Apps

This folder demonstrates how a platform team can expose observability as a reusable GitOps product.

The platform repository owns:

- OTel collector baselines.
- Gateway policies.
- Instrumentation templates.
- Dashboard and alert Helm templates.

Application repositories own:

- Small values files.
- Service metadata.
- SLO thresholds.
- Alert routing intent.

## Flow

```text
app repo values
  -> Argo CD Application
  -> platform-owned observability chart
  -> Instrumentation, dashboards, alerts, and workload patches
```

Use `root-application.yaml` as the parent app and `apps/*.yaml` as examples of child apps.
