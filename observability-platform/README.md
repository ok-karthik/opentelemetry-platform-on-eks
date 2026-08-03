# Observability Platform Templates

This folder is the "how this scales to 1000+ services" part of the demo. Treat it as the platform team's reusable template library, separate from the sample workload application.

## What Lives Here

- [01-app-onboarding](./01-app-onboarding): developer onboarding contract, example app-team values files, and language-specific OTel Operator instrumentation templates.
- [02-gateway-configuration](./02-gateway-configuration): central OTel Gateway policies, including collector routing patterns for multi-tenancy, and tail-sampling/filtering examples for telemetry budgeting.
- [03-dashboards-and-alerts](./03-dashboards-and-alerts): reusable dashboards for baseline golden signals and Helm-driven dashboard and alert generation patterns.
- [04-cluster-gitops-baseline](./04-cluster-gitops-baseline): GitOps patterns with Argo CD, and workload-cluster baseline templates like the stable regional gateway alias.
- [k8s-manifests](./k8s-manifests): deployable observability-cluster manifests — the OTel Gateway, its internal NLB, the Grafana ALB Ingress, and the golden-signal dashboard ConfigMap. Loki, Tempo, Mimir, and Grafana themselves are installed by Terraform from `terraform/observability-cluster/helm-values/`.

## Interview Talk Track

For a large global company, I would deploy this platform per region:

1. Workload clusters run lightweight OTel Collector DaemonSets.
2. DaemonSets enrich telemetry with Kubernetes metadata and forward to a private regional observability cluster.
3. Regional OTel Gateway fleets apply shared policy: memory limits, filtering, batching, tail sampling, routing, and backend export.
4. Teams onboard by adding standard labels/resource attributes and using dashboard/alert templates through GitOps.
5. Critical traces are preserved while healthy high-volume traffic is sampled down to manage cost.

## Scale Evolution

```text
Small demo:
apps cluster -> daemonset collector -> observability gateway -> LGTM

Enterprise regional platform:
many app clusters -> regional ingestion gateways -> processing gateways -> Datadog/Dynatrace/LGTM/AMP

High burst or backend outage protection:
many app clusters -> ingestion gateways -> Kafka/MSK buffer -> processing gateways -> backends
```

## Ownership Model

- App teams own instrumentation quality, service names, SLO intent, and dashboard values.
- Platform teams own collector baselines, routing policy, backend integrations, sampling defaults, and paved-road templates.
- Security/FinOps teams get centralized controls for secrets, retention, noisy telemetry, and tenant boundaries.

## Platform Product Model

```text
Developers declare observability intent in Git.
The platform renders standard instrumentation, dashboards, alerts, routing, and cost controls.
```

In practice:

1. App teams add a small values file from `onboarding/`.
2. The values file selects a language template from `instrumentation-templates/`.
3. Argo CD or Flux applies platform-owned templates from `gitops-app-of-apps/`.
4. Workload telemetry flows through the local DaemonSet collector.
5. The central gateway applies platform policy: filtering, semantic normalization, tail sampling, routing, and backend export.

## Demo

In the live demo, `k8s-manifests/` is the deployable slice. The other folders are the production templates I would standardize before onboarding hundreds of teams.
