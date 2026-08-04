# Agent Instructions and Project Context

This file gives AI agents the project mental model, repo structure, and working rules for this OpenTelemetry observability platform demo.

## Project Model

Treat this repository as a reference implementation for an internal observability product on Amazon EKS.

Although the directories currently live in one repository, reason about them as if they could be separate Git repositories:

- `observability-platform/`: platform-owned observability product templates, gateway policy, routing, dashboards, alerts, and cost controls.
- `apps-workload-cluster-1/`: application-team-owned workload repository that consumes the observability platform.
- `terraform/`: infrastructure provisioning for the workload EKS cluster and the dedicated observability EKS cluster.

The core telemetry flow is:

```text
Application container
  -> OpenTelemetry SDK or auto-instrumentation
  -> workload-cluster OTel Collector DaemonSet
  -> central observability-cluster OTel Gateway
  -> observability backend such as LGTM, Tempo, Loki, Mimir, Datadog, or another vendor
```

For platform-engineering discussions, use this ownership model:

- App teams own service code, service identity, instrumentation quality, SLO intent, alert thresholds, and dashboard values.
- Platform teams own collector baselines, gateway policy, backend integrations, sampling defaults, routing, tenant isolation, templates, and GitOps onboarding patterns.
- Security and FinOps teams rely on centralized controls for secrets, retention, tenant separation, routing, noisy telemetry, and telemetry cost.

## Current Repository Structure

```text
apps-workload-cluster-1/
  apps-src/
    golang-app/                 # Go demo service with programmatic OTel SDK setup
    python-app/                 # Python demo service using OTel auto-instrumentation
  k8s-manifests/
    otel-collector-daemonset.yaml
    golang-app/
      golang-product-service.yaml
      app-ingress.yaml
    python-app/
      python-product-info-service.yaml
      otel-instrumentation-python.yaml   # OTel Operator Instrumentation CR

observability-platform/
  README.md
  k8s-manifests/
    grafana-ingress.yaml
    grafana-dashboards-configmap.yaml
    otel-collector-gateway.yaml
    svc-nlb-otel-gateway.yaml
  01-app-onboarding/
    README.md
    service-onboarding-contract.md
    values-examples/                     # Per-language app-team values files
    instrumentation-manifests/           # Per-language Instrumentation CRs
  02-gateway-configuration/
    README.md
    otel-gateway-multitenant.yaml        # Tenant/team routing
    otel-gateway-tail-sampling.yaml      # Telemetry budgeting
  03-dashboards-and-alerts/
    README.md
    golden-signals/                      # Baseline dashboard JSON
    helm-chart/                          # Dashboard + alert generator
  04-cluster-gitops-baseline/
    README.md
    gitops-app-of-apps/
    workload-cluster-baseline/

terraform/
  apps-workload-cluster-1/       # Workload EKS cluster, ECR, networking, Helm installs
  observability-cluster/         # Dedicated observability EKS cluster and networking
    helm-values/                 # Loki/Tempo/Mimir/Grafana values (.tftpl)
    cluster-storage/             # gp3 StorageClass chart
    karpenter-provisioner/       # NodePool + EC2NodeClass chart
  main.tf

architecture-decisions-and-tradeoffs.md
CLAUDE.md                        # Entry point for Claude Code; points here
Makefile
README.md
```

`CLAUDE.md` at the repository root is a short pointer to this file plus the
day-to-day commands. This file stays the source of truth — when conventions
change, update here first and only adjust `CLAUDE.md` if the summary is now
wrong.

Ignore `.terraform/` generated module/provider content unless explicitly asked to inspect local Terraform state or generated modules.

## Important Configuration Concepts

### Workload Cluster Collector

`apps-workload-cluster-1/k8s-manifests/otel-collector-daemonset.yaml` runs an OpenTelemetry Collector as a DaemonSet.

It is responsible for:

- Receiving OTLP traces, metrics, and logs from workloads.
- Reading pod logs through `filelog`.
- Collecting node/pod metrics through `kubeletstats`.
- Enriching telemetry with Kubernetes metadata using `k8sattributes`.
- Forwarding enriched telemetry to the central observability gateway.

Keep this collector lightweight. It should enrich, batch, and forward. Heavy tail sampling, expensive transforms, backend-specific routing, and policy decisions belong in the gateway layer.

The collector runs with `hostNetwork: true` and `dnsPolicy: ClusterFirstWithHostNet`. Both are required together:

- `hostNetwork` binds the OTLP receivers on each node's own IP so workloads can reach their node-local agent via `status.hostIP`.
- `dnsPolicy` is set explicitly because the agent still resolves `otel-gateway-regional.monitoring.svc.cluster.local` through CoreDNS while sharing the host network namespace.

This matters because `k8sattributes` uses `filter.node_from_env_var: K8S_NODE_NAME`, which caches only the pods on its own node. Telemetry that arrives from a pod on a *different* node — which is exactly what happens when workloads send to the collector's ClusterIP Service — gets no `k8s.*` attributes at all. The failure is silent and partial: on an N-node cluster roughly (N-1)/N of telemetry loses its enrichment.

If you ever remove `node_from_env_var`, the Service target becomes safe again, at the cost of every collector watching every pod.

### Application Instrumentation

Python uses OTel Operator auto-instrumentation through pod annotations such as:

```yaml
instrumentation.opentelemetry.io/inject-python: "python-instrumentation"
```

The value must match the name of an `Instrumentation` CR in the same namespace —
here `python-instrumentation` in `default`.

Two things about the operator that are easy to get wrong:

- The Service it creates for a collector is named `<collector-name>-collector`.
  A DaemonSet declared as `otel-collector-agent` is reachable at
  `otel-collector-agent-collector`, never at the bare name.
- The operator does not overwrite an environment variable a container already
  declares. `OTEL_EXPORTER_OTLP_ENDPOINT` set on the Deployment wins over the
  `exporter.endpoint` in the `Instrumentation` CR, so the two must agree or the
  CR value is dead config.

Workloads target their **node-local** agent through the Downward API
(`status.hostIP`), not the collector's ClusterIP Service — see the k8sattributes
note below.

Go uses programmatic SDK setup in `apps-workload-cluster-1/apps-src/golang-app/telemetry.go`.

When adding language templates, prefer:

- Python, Java, Node.js, and .NET: OTel Operator `Instrumentation` CRs and pod annotations.
- Go: SDK helper package, shared bootstrap pattern, or documented code template.

Every service should set stable OpenTelemetry resource attributes:

```text
service.name
service.namespace
service.version
deployment.environment
team
tenant.id
```

These attributes power routing, dashboards, alert labels, ownership, cost allocation, and tenant-aware policy.

For Go, `OTEL_RESOURCE_ATTRIBUTES` only takes effect if the resource is built with `resource.WithFromEnv()`. `resource.New` applies exactly the detectors it is passed, so a bare `resource.New(ctx, resource.WithAttributes(...))` silently discards everything set through the environment and the attributes above never reach the backend. Auto-instrumented languages read the variable for free.

### Observability Gateway

`observability-platform/k8s-manifests/otel-collector-gateway.yaml` is the central gateway.

This is where platform policy should live:

- `memory_limiter` for collector self-protection.
- `filter/*` processors for noisy telemetry and health-check drops.
- `transform/*` processors for semantic normalization.
- `tail_sampling` for retaining errors and latency outliers while sampling healthy traffic.
- `batch` for efficient backend export.
- Backend exporters such as LGTM, Tempo, Loki, Mimir, Datadog, or other OTLP endpoints.

Important: if a processor is defined, verify it is also wired into the relevant service pipeline. For example, a `tail_sampling` processor only takes effect when listed in the `traces` pipeline processors.

### Routing and Multitenancy

`observability-platform/02-gateway-configuration/otel-gateway-multitenant.yaml` demonstrates tenant-aware routing.

The pattern is:

```text
Normalize tenant identity
  -> route by tenant/team/environment/resource attributes
  -> export to a tenant-specific backend, retention tier, or namespace
```

The `transform/tenant` processor ensures `tenant.id` exists, falling back to `service.namespace` and then `unallocated`.

The routing connectors route traces, metrics, and logs based on `resource.attributes["tenant.id"]`.

When extending this, keep app-team inputs simple. App repos should declare service metadata; platform-owned configs should decide where telemetry goes.

### Telemetry Budgeting

`observability-platform/02-gateway-configuration/otel-gateway-tail-sampling.yaml` shows gateway-level cost control.

Use tail sampling to:

- Keep 100% of error traces.
- Keep 100% of high-latency traces.
- Keep important tenant or service traffic.
- Sample down healthy high-volume traffic.

At enterprise scale, consider an ingestion gateway plus Kafka/MSK plus processing gateway pattern for burst tolerance and backend outage protection.

### Dashboards and Alerts

`observability-platform/03-dashboards-and-alerts/golden-signals/` contains baseline Grafana dashboards for service golden signals.

`observability-platform/03-dashboards-and-alerts/helm-chart/` demonstrates a GitOps model where:

- Platform owns reusable Helm templates.
- App teams own a small values file containing service name, team, Slack channel, SLOs, and thresholds.
- Argo CD or Flux renders and applies `GrafanaDashboard` and `PrometheusRule` resources.

Prefer self-service app-team onboarding through values and CRDs over hand-crafted dashboards or platform tickets.

## Scale Architecture

Use `architecture-decisions-and-tradeoffs.md` as the main architecture reference.

The preferred production evolution is:

```text
Small demo:
app cluster -> DaemonSet collector -> observability gateway -> LGTM

Enterprise regional platform:
many app clusters -> regional ingestion gateways -> processing gateways -> backends

High burst or backend outage protection:
many app clusters -> ingestion gateways -> Kafka/MSK -> processing gateways -> backends
```

Default to per-region observability deployments. Avoid unnecessary cross-region telemetry transfer because it increases egress cost, latency, and data residency risk.

## Development Guidelines

- Use `rg` and `rg --files` for repository searches.
- Preserve user changes. Do not revert unrelated working-tree changes.
- Keep OpenTelemetry collector pipeline changes explicit: receivers -> processors/connectors -> exporters.
- When changing collector configs, verify that all referenced receivers, processors, connectors, and exporters are actually used in `service.pipelines`. A declared-but-unwired component is inert and produces no error.
- When changing Terraform, run `terraform fmt` on modified `.tf` files and `terraform validate` from `terraform/`.
- When changing anything under `terraform/observability-cluster/helm-values/`, run `make helm-lint` and diff the rendered output. Helm accepts unknown value keys silently, so a wrong path yields a chart default rather than a failure.
- When changing the Go service, build it: `cd apps-workload-cluster-1/apps-src/golang-app && go build ./...`.
- When changing Kubernetes manifests, preserve the distinction between workload-cluster configs and observability-platform configs.
- When adding utility workflows, expose them through the `Makefile` when appropriate.
- Keep docs updated when changing architecture, ports, service names, cluster names, chart versions, or onboarding flows. That means `README.md`, this file, and `CLAUDE.md` if its summary is affected.

### Verification targets

```text
make helm-lint    # render pinned charts locally; no cluster needed
make k8s-status   # pods on both clusters, plus anything not Running
make grafana-password
```

## Terraform Provisioning Patterns

### Two-stage apply (REQUIRED — do not collapse into one apply)

The `make k8s-create` target runs two sequential Terraform applies:

**Stage 1** — Infra only, using explicit `-target` flags for every non-Helm resource. This ensures Helm providers never connect to a not-yet-healthy EKS API server.

**Stage 2** — Full `terraform apply -var="deploy_observability_stack=true"` which reconciles the Helm releases.

Use `-parallelism=20` on both stages. The granular make targets are:

```text
make k8s-create          # full two-stage run (recommended)
make k8s-create-infra    # Stage 1 only — safe to re-run after partial failure
make k8s-create-helm     # Stage 2 only — re-runs Helm install/upgrade only
```

Never collapse Stage 1 and Stage 2 into a single `terraform apply` without `-target` guards. The Helm provider resolves `module.eks.cluster_endpoint` at plan time and will attempt to talk to the API before nodes are healthy.

### Helm release reliability settings

Always set these on cert-manager and OTel Operator:

```hcl
wait          = true
atomic        = true   # rolls back on failure; keeps state clean for re-apply
wait_for_jobs = true   # waits for cert-manager CRD install Job before marking done
timeout       = 300
```

For the backend charts (loki, tempo, mimir-distributed, grafana):
- Use `wait = true` without `atomic = true`. Atomic rollback during a debug session destroys pods and makes it harder to inspect failure.
- Set realistic `timeout` values: loki=600, tempo=600, mimir=900, grafana=300.

### Pin every chart version — no exceptions

Chart versions are collected in the `local.chart_versions` map at the top of each `helm-charts.tf`. An unpinned `helm_release` re-resolves to whatever is newest on **every** apply, so a repo that has not changed can still produce a different cluster. This is not hypothetical here: `grafana/loki` added multi-GB memcached tiers and `mimir-distributed` moved to a Kafka-backed ingest path between two applies of an unpinned config, which took the stack from working to unschedulable.

When bumping a version, re-render before applying:

```bash
make helm-lint
```

Helm ignores unknown value keys **silently**. A renamed path does not fail the install; it falls back to the chart default. Rendering and diffing is the only reliable check.

### Backend chart values

Values live in `terraform/observability-cluster/helm-values/*.yaml.tftpl`, not in `set` blocks. Each file carries the reasoning inline; the traps worth knowing before editing:

**Loki** (`grafana/loki`, SingleBinary) — the chart's production defaults are far too large for a demo node. `chunksCache` requests 9830Mi and `resultsCache` 1229Mi; neither can be scheduled on a t3-class node, so the release hangs on `wait` until timeout. `lokiCanary` and the nginx `gateway` are also on by default. All four are disabled, which makes the query/push endpoint `loki:3100` rather than `loki-gateway`.

Set `limits_config.allow_structured_metadata: true` — Loki 3.x rejects every OTLP push without it.

**Mimir** (`mimir-distributed`) — three settings that must move together:

```yaml
kafka:
  enabled: false          # chart default true: a 1-CPU/1Gi Kafka StatefulSet
mimir:
  structuredConfig:
    ingest_storage:
      enabled: false      # hardcoded true in the chart's base config
    ingester:
      push_grpc_method_enabled: true   # hardcoded false — writes arrive via Kafka
      ring:
        replication_factor: 1          # otherwise 3 ingesters are needed for quorum
```

Disabling Kafka without re-enabling `push_grpc_method_enabled` leaves the distributor with no path to the ingester and every remote-write returns 500. Also disable `zoneAwareReplication` on `ingester` and `store_gateway` (default creates one StatefulSet per zone), plus `rollout_operator` and `overrides_exporter`.

The `mimir-gateway` service injects `X-Scope-OrgID: anonymous`, so neither Grafana nor the OTel gateway needs a tenant header — as long as both talk to the gateway rather than the distributor directly.

**Tempo** (`grafana/tempo`, monolithic) — every setting lives under the top-level `tempo:` key. There is no top-level `storage:` or `traces:` key, so `storage.trace.backend=s3` and `traces.otlp.grpc.enabled=true` are both accepted and both do nothing. Tempo stays on `backend: local`, writing traces to ephemeral pod storage while the S3 bucket stays empty. Use `tempo.storage.trace.*` and `tempo.receivers.*`.

This chart is marked deprecated upstream. It is kept because it is the only single-pod Tempo; migrate to `grafana/tempo-distributed` when the demo needs horizontal scale.

**Grafana** — the dashboard sidecar generates its own provider definition. Do not ship a ConfigMap containing a hand-written `dashboards.yaml` provider under the `grafana_dashboard` label; the sidecar drops it into the dashboard directory where Grafana fails to parse it as a dashboard.

### cert-manager version tracks the Kubernetes version

cert-manager v1.14 supports Kubernetes up to 1.29. Against a newer API server its webhook cannot serve, and the OTel Operator install then blocks behind a CA injection that never completes. The cluster currently runs 1.35 with cert-manager v1.21.1. Bump both together.

Use `crds.enabled` — `installCRDs` is the deprecated spelling.

### Collector images

The OTel Operator defaults to the slim `opentelemetry-collector-k8s` distribution, which does not ship every component these configs use (`groupbyattrs` among them). A collector referencing a component its binary lacks fails to start. Both the operator default and the collector manifests are pinned to `otel/opentelemetry-collector-contrib`.

The `loki` exporter is deprecated and removed from contrib — export logs with `otlphttp` to Loki's native OTLP endpoint (`http://loki...:3100/otlp`; the exporter appends `/v1/logs`).

### StorageClass ordering

Loki, Tempo, and Mimir all create PVCs. The `gp3` StorageClass is its own Helm release (`cluster-storage/`) that every stateful release lists in `depends_on` — with `-parallelism=20`, Terraform is otherwise free to start those releases before any StorageClass exists, leaving claims Pending until the Helm timeout.

EKS ships its own default `gp2`, so two default-annotated classes exist. Every PVC in `helm-values/` names `gp3` explicitly rather than relying on the admission plugin's tie-break.

**S3 IAM** — include `s3:GetBucketLocation` (Loki calls it on startup to resolve the region and 403s into CrashLoopBackOff without it) and the multipart actions `s3:AbortMultipartUpload`, `s3:ListBucketMultipartUploads`, `s3:ListMultipartUploadParts` (Mimir and Tempo upload blocks above 5MiB as multipart).

### Karpenter

- **Karpenter is deployed only on the observability cluster.** The apps cluster does not need it — it runs two app containers and a DaemonSet collector that fit within a single t3.medium managed node group.
- Karpenter chart is pinned to `1.0.6` (stable v1 release), `replicas = 1` for the demo.
- The `gp3` StorageClass used to live in this chart. It was moved to `cluster-storage/` because it has to exist before the backend charts run, and Karpenter installs after them.
- CRD API versions in `karpenter-provisioner/templates/`:
  - NodePool: `karpenter.sh/v1` (not v1beta1)
  - EC2NodeClass: `karpenter.k8s.aws/v1` (not v1beta1)
  - AMI: use `amiSelectorTerms: [{alias: al2023@latest}]` — not `amiFamily: Bottlerocket`

### EKS Add-ons

Always include `coredns` in `cluster_addons` on the observability cluster. In-cluster DNS must be healthy before Helm webhook admission calls fire (cert-manager, OTel Operator rely on it).

```hcl
cluster_addons = {
  coredns                = { most_recent = true }
  eks-pod-identity-agent = { most_recent = true }
  aws-ebs-csi-driver     = { most_recent = true }
}
```

### Node group sizing

The observability node group is driven by the `node_group_*` variables (they were previously declared but never referenced — `eks.tf` hardcoded the values). Default is 2× `t3.large` spot.

Measured request footprint of the trimmed stack, which is what the size is based on:

```text
Mimir (8 pods)   0.40 vCPU / 1728 MiB
Loki  (1 pod)    0.10 vCPU /  256 MiB
Tempo (1 pod)    0.10 vCPU /  256 MiB
Grafana          0.05 vCPU /  192 MiB
OTel gateway x2  0.20 vCPU /  512 MiB
Karpenter        0.25 vCPU /  256 MiB
plus cert-manager, OTel operator, LB controller, CoreDNS, EBS CSI, node agents
                 ~1.8 vCPU / ~4.4 GiB total
```

`t3.medium` (~3.2 GiB allocatable) × 2 leaves no room for Mimir compaction spikes or a spot reclaim, and PVC-bound StatefulSets cannot be rescheduled freely. Re-derive this table with `make helm-lint` after changing any values file.

### Node Group lifecycle protection

Add `lifecycle.ignore_changes = ["scaling_config[0].desired_size"]` to managed node groups that are also managed by Karpenter. Without this, Karpenter-driven scaling changes the desired count in AWS, and the next `terraform apply` tries to reset it — causing a node group update that can disrupt in-flight Helm installs.

## Productization Direction

When asked how to make this a reusable platform product, favor these additions:

- `observability-platform/onboarding/`: app-team values examples for Go, Python, Java, Node.js, and .NET.
- `observability-platform/instrumentation-templates/`: language-specific `Instrumentation` CRs and deployment patch examples.
- `observability-platform/gitops/`: Argo CD or Flux examples showing how workload repos consume platform-owned charts.
- A clear service onboarding contract documenting required labels, resource attributes, supported languages, dashboard templates, alert defaults, and escalation routing.
- A values-driven replacement for hardcoded gateway endpoints in workload collector manifests.
- A validated gateway pipeline that includes tail sampling where intended.

The key platform story is:

```text
Developers declare observability intent in Git.
The platform renders standard instrumentation, dashboards, alerts, routing, and cost controls.
```

