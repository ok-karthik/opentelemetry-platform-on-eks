# Agent Instructions and Project Context

This file gives AI agents the project mental model, repo structure, operational workflows, and working rules for this OpenTelemetry observability platform. It is the **single canonical source of truth** for repository conventions and technical architecture.

## Permissions & Command Execution

- **Kubernetes CLI (`kubectl`):** You have explicit, permanent permission to run all `kubectl *` and `kubectl --context *` commands directly across all clusters and namespaces without prompting the user.
- **Platform & Infrastructure:** You have explicit permission to run `make *`, `terraform *`, `docker *`, `go *`, and `aws *` commands without asking for confirmation.

## Project Model & Domain Layout

Treat this repository as a reference implementation for an internal observability product on Amazon EKS.

Although the directories currently live in one repository, reason about them as four distinct domains:

| Domain | Path | Ownership & Purpose |
|---|---|---|
| **Workloads** | `workloads/` | App-team-owned microservices (`golang-app`, `python-app`) and the per-node DaemonSet collector. |
| **Observability Platform** | `observability-platform/` | Central gateway runtime manifests (Two-tier Router/Processor, NLB, Grafana ALB, GoAlert, alert rules). |
| **Platform Product** | `platform-as-a-product/` | Platform product paved roads: onboarding contracts, 4 telemetry tiers, gateway policies, and GitOps baselines. |
| **Infrastructure** | `terraform/` | Platform infrastructure: Day-1 EKS base module + Day-2 BYOC observability stack module. |
| **Architecture** | `docs/` | Deep-dive architectural decisions, capacity planning (2k-200k QPS), multi-tenancy, and roadmap. |

### Topology Modes: Single-Cluster vs Multi-Cluster

The platform can be provisioned in two distinct deployment modes controlled via the `SINGLE_CLUSTER` Makefile variable:

1. **Single-Cluster Mode (`SINGLE_CLUSTER=true`, DEFAULT):**
   - Provisions a single EKS cluster (`terraform/`) running both workloads and the observability stack.
   - Slashes costs from ~$300/mo to **~$150/mo** (1× control plane, 1× NAT gateway, serverless AMP metrics).
   - Fast to deploy and iterate on without cross-VPC peering latency.
2. **Multi-Cluster Peered Mode (`SINGLE_CLUSTER=false`):**
   - Provisions separate EKS clusters across peered VPCs (`10.0.0.0/16` and `10.1.0.0/16`).
   - Demonstrates true multi-cluster regional ingestion over an internal AWS Network Load Balancer (NLB).

The core telemetry flow is:

```text
Application container (workload cluster / namespace)
  -> OpenTelemetry SDK, Operator auto-instrumentation, or OBI eBPF
  -> Node-local OTel Collector DaemonSet (status.hostIP Downward API)
  -> Central Observability Gateway (Tier 1 Router -> Tier 2 Processor)
  -> Backends: Amazon Managed Prometheus (AMP), S3-backed Loki & Tempo, or optional Kafka/OpenSearch
  -> Visualization & Escalation: Grafana (SigV4) & GoAlert pager
```

For platform-engineering discussions, use this ownership model:

- **App teams** own service code, service identity, instrumentation quality, SLO intent, alert thresholds, and dashboard values.
- **Platform teams** own collector baselines, gateway policy, backend integrations, sampling defaults, routing, tenant isolation, templates, and GitOps onboarding patterns.
- **Security and FinOps teams** rely on centralized controls for secrets, retention, tenant separation, routing, noisy telemetry, and telemetry cost.

## Current Repository Structure

The annotated directory tree lives in **[../README.md](../README.md)**, under
"Where things live" in the *What actually gets deployed* section — a table
mapping concept to path, plus a collapsed full tree that marks each directory
`DEPLOYED` or `TEMPLATE`. That tree is canonical. Do not restate it here; a
second copy drifts, and this file is the one agents read most.

What the tree does not say, and this file is responsible for:

- `workloads/` houses self-contained microservices (Go SDK & Python app) with their code, Dockerfiles, and deployment YAMLs, plus the node agent.
- `observability-platform/` contains active runtime gateway, Ingestion NLB, Grafana ALB, GoAlert, and alert rule manifests.
- `platform-as-a-product/` contains platform governance: service onboarding contracts, 4 levels of instrumentation, gateway policy templates, and Argo CD GitOps templates.
- `CLAUDE.md` at the repository root is a minimal pointer pointing directly to this file.

Ignore local `.terraform/` generated state and modules unless explicitly asked.

## Important Configuration Concepts

### Workload Cluster Collector

`workloads/otel-collector-daemonset.yaml` runs an OpenTelemetry Collector as a DaemonSet.

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

Go uses programmatic SDK setup in `workloads/apps-src/golang-app/telemetry.go`.

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

`observability-platform/bootstrap-k8s-manifests/otel-collector-gateway.yaml` is the central gateway.

This is where platform policy should live:

- `memory_limiter` for collector self-protection.
- `filter/*` processors for noisy telemetry and health-check drops.
- `transform/*` processors for semantic normalization.
- `tail_sampling` for retaining errors and latency outliers while sampling healthy traffic.
- `batch` for efficient backend export.
- Backend exporters such as LGTM, Tempo, Loki, Mimir, Datadog, or other OTLP endpoints.

Important: if a processor is defined, verify it is also wired into the relevant service pipeline. For example, a `tail_sampling` processor only takes effect when listed in the `traces` pipeline processors.

### Routing and Multitenancy

`observability-platform/platform-as-a-product/gateway-policies/otel-gateway-multitenant.yaml` demonstrates tenant-aware routing.

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

`observability-platform/platform-as-a-product/gateway-policies/otel-gateway-tail-sampling.yaml` shows gateway-level cost control.

Use tail sampling to:

- Keep 100% of error traces.
- Keep 100% of high-latency traces.
- Keep important tenant or service traffic.
- Sample down healthy high-volume traffic.

At enterprise scale, consider an ingestion gateway plus Kafka/MSK plus processing gateway pattern for burst tolerance and backend outage protection.

### Dashboards and Alerts

`observability-platform/platform-as-a-product/dashboards-and-alerts/golden-signals/` contains baseline Grafana dashboards for service golden signals.

`observability-platform/platform-as-a-product/dashboards-and-alerts/helm-chart/` demonstrates a GitOps model where:

- Platform owns reusable Helm templates.
- App teams own a small values file containing service name, team, Slack channel, SLOs, and thresholds.
- Argo CD or Flux renders and applies `GrafanaDashboard` and `PrometheusRule` resources.

Prefer self-service app-team onboarding through values and CRDs over hand-crafted dashboards or platform tickets.

### Meta-Monitoring

The OpenTelemetry platform must monitor itself. 
- Collectors (gateways and agents) expose metrics on `:8888` and `:8889`.
- Mimir Ruler evaluates alerts for backpressure (`otelcol_receiver_refused_*`), data loss (`otelcol_processor_dropped_*`), and silence/down instances.
### Amazon Managed Prometheus (AMP) vs. Self-Hosted Mimir

By default, this repository enables Amazon Managed Service for Prometheus via `use_amazon_managed_prometheus = true` in `terraform.tfvars`:

- **AMP Mode (Default):** Serverless, zero-maintenance metric workspace (`aws_prometheus_workspace.amp`). The OTel Gateway exports via `prometheusremotewrite` authenticated with AWS SigV4 (`sigv4auth` extension backed by EKS Pod Identity). Grafana queries AMP natively with SigV4 enabled. This eliminates 10 stateful pods (distributor, ingester, querier, ruler, alertmanager, compactor, etc.) and reduces the cluster memory request footprint by **~1.9 GiB**.
- **Mimir Mode (`use_amazon_managed_prometheus = false`):** Deploys self-hosted `mimir-distributed` writing blocks directly to S3 with Replication Factor 1 (`ring.replication_factor: 1`). Use this when full open-source autonomy or local testing without AWS managed service billing is desired.

### Zero-Cost S3 Gateway VPC Endpoints

Both the workload VPC and the observability VPC provision an `aws_vpc_endpoint` of type `Gateway` for `com.amazonaws.us-east-1.s3`:

- S3 traffic from Loki (logs) and Tempo (traces) is routed directly over AWS internal network routes.
- **FinOps Impact:** Completely bypasses NAT Gateways for S3 telemetry uploads at **$0.00/GB data transfer**, preventing NAT Gateway bandwidth charges ($0.045/GB) and eliminating connection scaling bottlenecks.

### Container Image Delivery (Docker Hub vs. ECR)

All workload demo services are published as public multi-arch images on Docker Hub:
- `okkarthik/golang-product-service:latest`
- `okkarthik/python-product-info-service:latest`

Terraform ECR repositories (`terraform/ecr.tf`) have been removed. Application manifests deploy directly without requiring AWS account ID interpolation, ECR authorization tokens, or pre-created registries.

### The 4 Levels of Telemetry Instrumentation

Enterprise observability combines complementary instrumentation tiers (see `observability-platform/platform-as-a-product/onboarding/instrumentation-tiers-and-ebpf.md`):

1. **Level 1: Kernel-Space eBPF (OBI DaemonSet):** Zero-code instrumentation inside the Linux kernel. Catches what runtimes miss: instant `OOMKilled` (Exit 137), cross-AZ TCP retransmits, CPU CFS throttling (`runqlat`), and uninstrumented legacy binaries (Nginx, Envoy, CoreDNS).
2. **Level 2: Runtime Auto-Instrumentation (OTel Operator):** Injected via pod annotations (`instrumentation.opentelemetry.io/inject-*`). Injects runtime hooks for Python, Java, Node.js, and .NET. Captures full application exceptions, stack traces, and database queries (`SELECT * FROM ...`).
3. **Level 3: Programmatic SDK (Go SDK / OpenTelemetry API):** Explicit telemetry bootstrap (`telemetry.go`). Essential for compiled binaries (Go/Rust/C++) and domain-specific business metrics, internal span lifecycle tracking, and custom baggage propagation.
4. **Level 4: Commercial Proprietary Agents (Datadog, Dynatrace):** Heavyweight proprietary agents that create vendor lock-in. This platform uses the OTel Gateway as an in-VPC "FinOps Firewall" to filter and compress telemetry before exporting to commercial SaaS when mandated.

## Scale Architecture

Use `docs/architectural-decisions.md` as the main architecture reference.

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

### Before You Change Anything (Pre-Flight Checklist)

- **Helm values**: run `make helm-lint`. Helm ignores unknown value keys silently, so a mistyped path leaves the chart default in place instead of failing. Rendering and diffing is the only reliable check.
- **Terraform**: run `terraform fmt -check` on modified `.tf` files, then `terraform validate` from `terraform/` (or `terraform/single-cluster/`).
- **Collector configs**: verify every declared receiver, processor, connector, and exporter actually appears in `service.pipelines`. A declared-but-unwired component is inert and produces no error.
- **Chart versions**: pin them in the `local.chart_versions` map at the top of each `helm-charts.tf`.
- **Go service**: `cd workloads/apps-src/golang-app && go build ./...`.

### Common Commands

```bash
make k8s-create        # two-stage Terraform apply (default: SINGLE_CLUSTER=true, ~$150/mo)
make k8s-create SINGLE_CLUSTER=false # dual-cluster peered VPC topology (~$300/mo)
make k8s-context       # configure kubeconfig contexts for the clusters
make k8s-deploy-all    # deploy gateway, collectors, and workload demo apps
make k8s-status        # check pod health across all namespaces (reports non-Running pods)
make k8s-dashboards    # port-forward Grafana to localhost:3000
make grafana-password  # fetch auto-generated admin password
make helm-lint         # render pinned charts locally without an active cluster
make k8s-destroy       # tear everything down
```

### Things That Are Easy to Get Wrong Here (Top Traps)

Each of these installs cleanly and fails later silently. They are detailed throughout this document:

1. **Tempo values nesting:** All settings live strictly under `tempo:`. A top-level `storage:` or `traces:` key is silently accepted and ignored, leaving traces on ephemeral local disk while S3 remains empty.
2. **Mimir Kafka decoupling:** When disabling Kafka (`kafka.enabled: false`), you MUST set `ingester.push_grpc_method_enabled: true` and `replication_factor: 1`. Missing this leaves the distributor with no path to the ingester and every remote-write returns HTTP 500.
3. **Loki cache memory requests:** Loki chart defaults request ~9.6 GiB RAM for `chunksCache`. Must be disabled along with `resultsCache` and canary on demo nodes. Set `limits_config.allow_structured_metadata: true` or Loki 3.x rejects every OTLP push.
4. **cert-manager API compatibility:** Must track the Kubernetes version (Kubernetes 1.35 requires cert-manager v1.21.1+). Use `crds.enabled: true` (`installCRDs` is deprecated).
5. **Workload agent addressing:** Workloads MUST target their node-local agent via Downward API `status.hostIP:4317`. Using the ClusterIP Service silently breaks `k8sattributes` node-filtering, causing (N-1)/N pods to lose Kubernetes metadata.
6. **OTel Operator Service naming:** Operator exposes collectors as `<collector-name>-collector` (e.g. `otel-collector-agent-collector`), never at the bare name.
7. **Logstash JSON codec:** OTel Gateway's `kafka/logs` exporter must set `encoding: otlp_json` explicitly. Default is binary protobuf (`otlp_proto`), which Logstash's stock JSON codec drops silently without erroring.
8. **GoAlert version tags:** Do not pin by Docker tag (v0.34.1 tag does not exist on Docker Hub); pin strictly by sha256 digest (`goalert/goalert@sha256:...`).
9. **Go telemetry environment variables:** `OTEL_RESOURCE_ATTRIBUTES` only takes effect if Go builds the resource with `resource.WithFromEnv()`. Bare `resource.New` silences environment variables.
10. **StorageClass ordering:** Always ensure `cluster-storage/` (gp3) is created before stateful backend charts run via Terraform `depends_on`.

### Scope Rules & Repository Integrity

- **Preserve user changes:** Do not revert unrelated working-tree edits.
- **Maintain domain separation:** Keep the boundary between `workloads/` (application code & manifests), `observability-platform/` (central platform product), and `terraform/` (cloud infra) intact.
- **Keep documentation synchronized:** When changing architecture, ports, service names, cluster names, chart versions, or onboarding flows, update `README.md` and this file.
- **Directory tree updates:** The canonical directory tree lives exclusively in [README.md](../README.md). When adding or renaming directories, update the tree in `README.md` only.

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

Values live in `terraform/modules/observability-stack/helm-values/*.yaml.tftpl`, not in `set` blocks. Each file carries the reasoning inline; the traps worth knowing before editing:

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

**Mimir ruler** (`ruler.enabled`, `ruler_storage.backend: local`) — the ruler looks for rule groups in `<ruler_storage.local.directory>/<tenant ID>/`, and the tenant ID here is literally the string `anonymous` (same org the gateway injects). `ruler.extraVolumeMounts` mounts the `mimir-ruler-rules` ConfigMap at `.../anonymous` directly — mount it one level higher (at the bare `directory` path) and the ruler starts clean with zero rule groups loaded, no error, no alerts, nothing in the ruler's own `/ruler/rule_groups` API to indicate anything is wrong. `local` is a read-only ruler storage backend; there is no config-API path to create or delete rules against it, which is intentional here — rules are meant to live in git, not be pushed at runtime. `ruler.alertmanager_url` needs no override: the chart's own default is a `dnssrvnoa+` SRV lookup against `<fullname>-alertmanager-headless`, which resolves correctly once `alertmanager.enabled: true` creates that headless Service — setting it explicitly is redundant and one more place a hostname can drift from the fullname.

**Mimir alertmanager** — `alertmanager.fallbackConfig` (a **top-level** chart value, not under `mimir.structuredConfig`) is the config every tenant runs unless something pushes a per-tenant config through the Alertmanager config API. Nothing in this repo pushes one, so `fallbackConfig` is not a fallback in practice — it is *the* config. `alertmanager_storage` (S3) is unrelated to this: it holds runtime state (silences, notification log), not the routing tree.

**OpenSearch** (`opensearch-project/opensearch`) — `protocol` and `plugins.security.disabled` have to move together, same shape as the Kafka/`push_grpc_method_enabled` trap above. `protocol: https` is the chart default; disabling the security plugin also disables the TLS it terminates, and leaving `protocol` on `https` means the chart's own readiness probes hit a plaintext port expecting TLS and never pass — the release hangs until timeout, not a clean failure. OpenSearch Dashboards needs the paired `DISABLE_SECURITY_DASHBOARDS_PLUGIN=true` env var on its own side — enabling one without the other means Dashboards tries to authenticate against a security plugin the backend doesn't have, and every login fails.

**Logstash → OpenSearch** — the gateway's `kafka/logs` exporter must set `encoding: otlp_json` explicitly; the kafka exporter's default is `otlp_proto` (binary), which Logstash's stock `json` codec cannot decode. Getting this wrong doesn't error anywhere — messages land in Kafka, Logstash's kafka input reads them, and `json` codec parsing just fails silently per-message, so `_index_bootstrap` succeeds, OpenSearch comes up clean, and no documents ever arrive. Check `kubectl logs -n monitoring -l app=logstash-logstash` for codec errors if OpenSearch Dashboards shows an empty index.

**GoAlert** — publishes `latest` and branch-name tags to Docker Hub but stopped publishing numbered version tags there after v0.31.0 (2023), even though GitHub Releases keeps tagging real versions. Pin by digest (`goalert/goalert@sha256:...`), not by a tag that looks like a version but isn't one — `goalert/goalert:v0.34.1` does not exist on Docker Hub and will fail to pull. GoAlert's admin user and its Alertmanager integration key are both account state created interactively (`goalert add-user` CLI, then the web UI's Setup Wizard) — there is no manifest that creates either declaratively; don't try to invent one.

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
Mimir (10 pods)  0.46 vCPU / 1888 MiB   # incl. ruler (50m/128Mi) + alertmanager (10m/32Mi)
Loki  (1 pod)    0.10 vCPU /  256 MiB
Tempo (1 pod)    0.10 vCPU /  256 MiB
Grafana          0.05 vCPU /  192 MiB
OTel gateway x2  0.20 vCPU /  512 MiB
Alert sink       0.01 vCPU /   32 MiB
OpenSearch       0.10 vCPU /  768 MiB
OpenSearch Dash  0.05 vCPU /  256 MiB
Logstash         0.10 vCPU /  512 MiB
GoAlert + PG     0.10 vCPU /  256 MiB   # goalert 50m/128Mi + postgres 50m/128Mi
Karpenter        0.25 vCPU /  256 MiB
plus cert-manager, OTel operator, LB controller, CoreDNS, EBS CSI, node agents
                 ~2.2 vCPU / ~6.4 GiB total
```

The ELK path (OpenSearch/Dashboards/Logstash) and GoAlert+Postgres together add
~0.35 vCPU / ~1.8 GiB over the LGTM-only footprint — still comfortably inside
2× `t3.large` (~3.8 vCPU / ~14.6 GiB allocatable), no node group resize
needed, but worth knowing before adding a fourth stateful backend on top of it.

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

