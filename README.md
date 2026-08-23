# OpenTelemetry Observability Platform on EKS

A working multi-cluster observability platform on Amazon EKS: application teams emit OTLP and get traces, metrics, and logs correlated in Grafana, while the platform team owns enrichment, sampling, routing, retention, and cost in one place instead of in every service.

The problem it solves is ownership. Without a platform layer, every team picks its own agent, its own sampling rate, and its own backend, and the observability bill grows linearly with traffic while nobody can follow a request across two services. Here, applications declare *what* they are (`service.name`, `team`, `deployment.environment`) and the platform decides *where telemetry goes, what survives sampling, and how long it is kept*.

Everything below is deployed by the code in this repository. Where something is a template rather than a running component, it is marked **not implemented** — see [What is not implemented](#what-is-not-implemented).

---

## Enterprise Architecture Patterns

This platform has been upgraded to implement enterprise-grade observability patterns:

1. **eBPF & Exemplars (Zero-Code Instrumentation):** OTel agents (DaemonSets) are configured with OBI (OpenTelemetry eBPF) to natively capture RED (Rate, Errors, Duration) metrics from the kernel without developer intervention. Metrics include Exemplars, intrinsically linking metric spikes directly to trace IDs.
2. **Two-Tier Gateway (Consistent Hashing):** The central OTel Gateway is split into two tiers:
   - **Tier 1 (Router):** A Deployment that hashes trace traffic by `traceID` and routes it.
   - **Tier 2 (Processor):** A StatefulSet that receives the hash-aligned traces. This guarantees every span for a trace lands on the exact same replica, enabling accurate **tail-based sampling**.
3. **Kafka Buffer & ELK Analytics:**
   - **Why ELK?** Elasticsearch provides unparalleled full-text search and complex query capabilities, while Logstash provides robust Grok parsing for legacy log formats.
   - **Why Kafka?** Kafka acts as a shock absorber. During massive traffic spikes or Elasticsearch rollover failures, direct ingestion leads to dropped logs. Kafka holds the data securely until Logstash can process it. 
   - **Cloud Services:** In production, Kafka is provided via **Amazon MSK** and ELK via **Amazon OpenSearch Serverless** for zero-ops scale. A local Kafka stub is deployed in the cluster for validation.

## Architecture

```mermaid
flowchart TD
    subgraph "Workload Cluster (App Team)"
        App1[App Pods]
        App2[App Pods]
        Agent[OTel Agent DaemonSet\n(eBPF Auto-Instrumentation)]
        
        App1 -->|Zero-code RED metrics & Traces| Agent
        App2 -->|Zero-code RED metrics & Traces| Agent
    end

    subgraph "Observability Cluster (Platform Team)"
        NLB[Internal Network Load Balancer]
        
        subgraph "Tier 1: Router (Deployment)"
            Router[OTel Gateway Tier 1\n(Routing & Hash by traceID)]
        end

        subgraph "Tier 2: Processor (StatefulSet)"
            Processor[OTel Gateway Tier 2\n(Tail Sampling & processing)]
        end

        Kafka[(Amazon MSK / Kafka Stub)]
        
        subgraph "Log Analytics Pipeline"
            Logstash[Logstash]
            Elasticsearch[(Amazon OpenSearch / ES\nHot/Warm/Cold)]
        end

        subgraph "LGTM Stack"
            Tempo[(Tempo)]
            Mimir[(Mimir)]
        end
    end

    Agent -->|OTLP| NLB
    NLB --> Router
    Router -->|Load Balanced\nby traceID| Processor
    Processor -->|Logs| Kafka
    Kafka --> Logstash
    Logstash --> Elasticsearch
    Processor -->|Traces| Tempo
    Processor -->|Metrics| Mimir
```

Two EKS clusters (Kubernetes 1.35, `us-east-1`) in peered VPCs — `10.0.0.0/16` for workloads, `10.1.0.0/16` for observability. Lightweight collectors run next to workloads; a central two-tier gateway fleet on the observability cluster owns policy; logs are buffered by Kafka before shipping to ELK, while traces and metrics persist to LGTM backends.

## The telemetry path

1. **A Go service calls a Python service** and propagates W3C trace context. Go uses the OTel SDK programmatically (`telemetry.go`); Python is auto-instrumented by the OTel Operator through a pod annotation. Both print `trace_id=` into stdout logs.
2. **Each pod exports OTLP to the collector on its own node**, resolved through the Downward API (`status.hostIP:4317`) — not through a ClusterIP Service. This is load-bearing; see [Decision 5](#5-node-local-routing-via-statushostip).
3. **The DaemonSet agent enriches and forwards.** It receives OTLP, tails `/var/log/pods` via `filelog`, scrapes `kubeletstats`, attaches `k8s.*` attributes via `k8sattributes`, stamps `team=product`, batches, and ships everything to the regional gateway over an internal NLB.
4. **The gateway applies platform policy.** `memory_limiter`, health-check and noisy-span filters, OTTL semantic-convention normalization, trace-ID-affinity load balancing, then `tail_sampling`, then `batch`.
5. **Backends store, Grafana correlates.** Traces to Tempo, metrics to Mimir via Prometheus remote-write, logs to Loki over native OTLP — all on S3 with 7-day retention. Grafana links logs to traces (`derivedFields` on `trace_id`) and traces back to logs and metrics (`tracesToLogsV2`, `tracesToMetrics`).

## What actually gets deployed

### Observability cluster

| Component | Chart / image | Version | Shape |
|---|---|---|---|
| Loki | `grafana/loki` | 7.2.0 | SingleBinary, 1 pod, S3 |
| Tempo | `grafana/tempo` | 1.24.4 | monolithic, 1 pod, S3 |
| Mimir | `grafana/mimir-distributed` | 6.1.0 | 8 pods, 1 replica each, S3 |
| Grafana | `grafana/grafana` | 10.5.15 | 1 pod, 3 datasources |
| OTel Gateway (Tier 1 & 2) | `otel/opentelemetry-collector-contrib` | 0.156.0 | Deployment & StatefulSet |
| Kafka Stub | `bitnami/kafka` | 3.6 | 1 pod |
| OTel Operator | `opentelemetry-operator` | 0.120.0 | 1 pod |
| cert-manager | `jetstack/cert-manager` | v1.21.1 | 3 pods |
| AWS LB Controller | `eks/aws-load-balancer-controller` | 3.4.3 | ALB + NLB |
| Karpenter | `oci://public.ecr.aws/karpenter` | 1.0.6 | NodePool + EC2NodeClass |
| gp3 StorageClass | local chart `cluster-storage/` | — | installed before any PVC |

Mimir runs distributor, ingester, querier, query-frontend, query-scheduler, store-gateway, compactor, and gateway — one replica each. Alertmanager, ruler, overrides-exporter, rollout-operator, MinIO, and the bundled Kafka are disabled.

Node group: 2× `t3.large` spot (min 2, max 6), plus Karpenter for burst. Measured request footprint of the trimmed stack is ~1.8 vCPU / ~4.4 GiB.

### Workload cluster

| Component | Version | Notes |
|---|---|---|
| OTel Collector agent | contrib 0.156.0 | DaemonSet, `hostNetwork: true` |
| OTel Operator | 0.120.0 | injects Python auto-instrumentation |
| cert-manager | v1.21.1 | webhook TLS for the operator |
| AWS LB Controller | 3.4.3 | ALB for the demo app |
| Go + Python demo services | — | built and pushed to ECR by GitHub Actions |

Node group: 2× `t3.medium` spot (min 1, max 4). No Karpenter — two app pods and a DaemonSet fit a single node group.

### AWS

Five S3 buckets (Loki, Tempo, Mimir blocks/ruler/alertmanager — the last two are provisioned but their components are off), one IAM role reached through **EKS Pod Identity** associations, one NAT gateway per VPC, one internal NLB for OTLP ingest, one internet-facing ALB for Grafana, five 10 GiB gp3 volumes. ECR repositories for both service images. CI authenticates to AWS via GitHub OIDC, not static keys.

### Where things live

| Path | Contents |
|---|---|
| `terraform/` | Both clusters, VPC peering, S3, IAM |
| `terraform/observability-cluster/helm-values/` | Loki / Tempo / Mimir / Grafana values, with the reasoning inline |
| `apps-workload-cluster-1/` | Demo services, their manifests, the DaemonSet collector |
| `observability-platform/k8s-manifests/` | Gateway, NLB, Grafana ingress, dashboards — the deployed platform |
| `observability-platform/01-…04-…/` | Onboarding contract, policy templates, dashboard generator, GitOps baseline |
| `.agents/AGENTS.md` | Long-form conventions and chart traps |
| `architecture-decisions-and-tradeoffs.md` | Five collector topology patterns compared, with diagrams |

<details>
<summary>Full tree, annotated with what is deployed and what is a template</summary>

```text
apps-workload-cluster-1/            # app-team-owned; reason about it as its own repo
  apps-src/
    golang-app/                     # Go service, programmatic OTel SDK (telemetry.go)
    python-app/                     # Python service, Operator auto-instrumentation
  k8s-manifests/
    otel-collector-daemonset.yaml   # DEPLOYED  agent + ExternalName alias + RBAC
    golang-app/                     # DEPLOYED  Deployment, Service, ALB Ingress
    python-app/                     # DEPLOYED  Deployment, Service, Instrumentation CR

observability-platform/             # platform-team-owned; the product surface
  k8s-manifests/                    # DEPLOYED  everything the Makefile applies
    otel-collector-gateway.yaml     #   gateway CR: filters, OTTL, tail sampling, exporters
    svc-nlb-otel-gateway.yaml       #   internal NLB, instance target type
    grafana-ingress.yaml            #   internet-facing ALB, HTTP only
    grafana-dashboards-configmap.yaml
  01-app-onboarding/                # TEMPLATE  contract + per-language values and CRs
  02-gateway-configuration/         # TEMPLATE  tenant routing, real sampling budget
  03-dashboards-and-alerts/
    golden-signals/                 # DEPLOYED  via the ConfigMap above
    helm-chart/                     # TEMPLATE  needs Prometheus Operator CRDs
  04-cluster-gitops-baseline/       # TEMPLATE  Argo CD app-of-apps; Argo CD not installed

terraform/
  main.tf                           # both cluster modules + VPC peering and routes
  apps-workload-cluster-1/          # EKS, VPC, ECR, cert-manager/Operator/LB controller
  observability-cluster/            # EKS, VPC, S3, IAM, Pod Identity, full LGTM stack
    helm-values/                    # Loki/Tempo/Mimir/Grafana .tftpl, reasoning inline
    cluster-storage/                # gp3 StorageClass — installs before any PVC
    karpenter-provisioner/          # NodePool + EC2NodeClass
```

The per-app nesting under `k8s-manifests/` is why the Makefile uses `kubectl apply -R`
and `kubectl delete -R`; a non-recursive delete skips both app subdirectories and
leaves the Deployments and the ALB running.

</details>

## Decisions and trade-offs

| Decision | Chosen | Rejected | Cost of the choice |
|---|---|---|---|
| Collector topology | DaemonSet agent + central gateway | Sidecar-per-pod; agent-only | One more network hop and a fleet to run |
| Sampling | Tail sampling at the gateway | Head sampling in the SDK | Stateful gateway, trace-ID affinity required |
| Cluster layout | Two clusters, peered VPCs | One cluster, separate namespace | ~$73/mo extra control plane, peering to manage |
| Backends | Self-hosted LGTM on S3 | AMP + AMG, or a SaaS vendor | You now operate four stateful systems |
| Agent addressing | `status.hostIP` per node | Collector ClusterIP Service | Workloads need Downward API boilerplate |

### 1. DaemonSet agent plus a central gateway

**Chosen.** A per-node collector that only enriches, batches, and forwards, feeding a horizontally scaled gateway on a separate cluster that owns all policy.

**Rejected — sidecar per pod.** Resource cost scales with pod count rather than node count, and a sidecar sees exactly one service, so tail sampling across a distributed trace is impossible. **Rejected — agent-only, exporting straight to backends.** Every node then holds backend credentials, every policy change is a fleet-wide DaemonSet rollout, and backends see N connections instead of a handful.

**What it cost.** An extra hop and its failure mode: if the gateway is down, agents buffer in memory and eventually drop. There is no persistent queue in this repo — see [10× scale](#what-id-do-differently-at-10-scale). It also splits debugging across two collector configs, which is why `k8sattributes` enrichment failures are easy to miss (they are silent and partial).

**Why the split is drawn where it is.** Enrichment needs node-local context, so it must run on the node. Sampling needs a whole trace, so it cannot. That single fact determines the architecture.

### 2. Tail sampling at the gateway

**Chosen.** `tail_sampling` with a 10s decision window and 10,000 in-flight traces, wired into the traces pipeline: keep all `ERROR` traces, keep everything slower than 2000 ms, and apply a probabilistic policy to the rest.

**Rejected — head sampling in the SDK.** The decision is made on the first span, before anyone knows whether the request failed or was slow. At 1% head sampling you keep 1% of your errors, which is exactly backwards: the traces worth keeping are the rare ones.

**What it cost.** Tail sampling is stateful — every span of a trace must reach the *same* gateway replica. That forced a two-stage pipeline: an entry pipeline whose only job is a `loadbalancing` exporter keyed on `traceID`, resolving gateway pods through the Kubernetes API and re-emitting to port 4319, and a second pipeline that receives on 4319 and actually samples. It doubles the intra-cluster hops and makes the gateway a stateful component that cannot be scaled down carelessly.

**Honest caveat.** The deployed policy sets `sampling_percentage: 100.0` for healthy traces — the machinery samples, the budget is deliberately off so the demo shows every trace. [`otel-gateway-tail-sampling.yaml`](observability-platform/02-gateway-configuration/otel-gateway-tail-sampling.yaml) is the template with a real budget (5% of healthy traffic, 500 ms latency threshold); it is a policy example, **not deployed**.

### 3. Two clusters instead of one

**Chosen.** A dedicated observability cluster in its own VPC, peered to the workload VPC. Telemetry crosses the peering link over an *internal* NLB; nothing about the path touches the public internet.

**Rejected — one cluster with a `monitoring` namespace.** Cheaper and simpler, but the failure mode is that the thing you use to debug an incident is running on the cluster having the incident. A node-pressure event or a bad workload rollout takes the telemetry with it, and Mimir's compaction spikes compete with application pods for the same nodes.

**What it cost.** A second EKS control plane (~$73/month), a second NAT gateway, VPC peering routes in both directions, and a real constraint on the NLB: `nlb-target-type: instance` is set rather than `ip`, because peered-VPC traffic to pod IPs takes an asymmetric return path. That is one line of annotation hiding a day of packet-level debugging.

**What it bought.** A genuine blast-radius boundary, independent scaling (the observability cluster runs Karpenter, the workload cluster does not need it), and the ability to demonstrate the multi-cluster fan-in that a regional platform actually looks like.

### 4. Self-hosted LGTM on S3 instead of managed

**Chosen.** Loki, Tempo, Mimir, and Grafana from their individual upstream charts, all backed by S3, all reached through EKS Pod Identity rather than static credentials.

**Rejected — Amazon Managed Prometheus + Managed Grafana.** Less to operate, but AMP is metrics only: traces and logs still need X-Ray and CloudWatch, so you get three query languages and no single correlated view. **Rejected — Datadog or an equivalent SaaS.** The best operator experience of the three and the reason it appears as Pattern 1–4 in [`architecture-decisions-and-tradeoffs.md`](architecture-decisions-and-tradeoffs.md), but per-host and per-GB pricing makes the observability bill a function of traffic, and it puts the exit cost of the platform outside your control.

**Rejected — the all-in-one `lgtm` chart.** It was the previous implementation here. Convenient, but it hides which component owns which setting, and it cannot be tuned per component. Migrating to four individual charts is what made every trade-off below visible.

**What it cost.** Four stateful systems to run, and each one has a default that installs cleanly and fails later:

| Trap | Symptom |
|---|---|
| Loki `chunksCache` requests 9830Mi | Unschedulable on any demo node; Helm blocks until timeout |
| Mimir 6.x hardcodes `ingest_storage.enabled` and `push_grpc_method_enabled: false` | Disable Kafka without flipping the gRPC push method back and every remote-write returns 500 |
| Tempo values are namespaced under `tempo:` | A top-level `storage:` key is accepted and ignored; traces go to ephemeral disk while the S3 bucket stays empty |
| cert-manager version tracks the Kubernetes version | v1.14's webhook cannot serve a 1.35 API server; the OTel Operator then hangs on CA injection forever |
| Unpinned charts re-resolve on every apply | Loki grew memcached tiers and Mimir adopted Kafka between two applies of an unchanged repo |
| `gp3` StorageClass ordering | With `-parallelism=20`, Helm releases start before any StorageClass exists and PVCs sit Pending |

Every chart version is therefore pinned in a `local.chart_versions` map, and values live in `.yaml.tftpl` files rather than Terraform `set` blocks so `make helm-lint` can render and diff them. Helm ignores unknown value keys **silently**, so rendering is the only reliable check that a value path is real. Long-form detail for each trap is in [`.agents/AGENTS.md`](.agents/AGENTS.md).

### 5. Node-local routing via `status.hostIP`

**Chosen.** Workloads resolve their own node's IP through the Downward API and export to `http://$(HOST_IP):4317`. The collector runs `hostNetwork: true` with `dnsPolicy: ClusterFirstWithHostNet`.

**Rejected — the collector's ClusterIP Service.** It is the obvious choice and it is silently wrong here. `k8sattributes` is configured with `filter.node_from_env_var: K8S_NODE_NAME`, which caches only the pods on its own node — that is what keeps the API watch cheap at scale. Telemetry arriving from a pod on a *different* node gets no `k8s.*` attributes at all. Routing through the Service round-robins across nodes, so on an N-node cluster roughly (N-1)/N of your telemetry loses its enrichment, with no error anywhere.

**What it cost.** Every workload needs the `HOST_IP` Downward API block, and the collector takes a host port. The alternative is dropping `node_from_env_var` and letting every collector watch every pod — fine at ten nodes, expensive at a thousand. The demo services carry the boilerplate; at scale it belongs in a mutating webhook or a shared Helm library chart, which is **not implemented** here.

### 6. Smaller decisions worth naming

- **EKS Pod Identity over IRSA.** The trust policy is static (`pods.eks.amazonaws.com`) with no OIDC provider URL to thread through Terraform, so the IAM role can be created before the cluster's OIDC issuer exists. Cost: Pod Identity is EKS-only, so the same module would not lift to another Kubernetes distribution.
- **Two-stage Terraform apply.** `make k8s-create` runs an infra-only apply with explicit `-target` flags, then a second apply that installs Helm. Collapsing them makes the Helm provider resolve `module.eks.cluster_endpoint` at plan time and dial an API server that is not serving yet. Cost: `-target` is officially an escape hatch, and the target list is a maintenance burden that must be updated when resources are added.
- **`otel/opentelemetry-collector-contrib` pinned everywhere.** The Operator defaults to the slim `opentelemetry-collector-k8s` distribution, which omits components these pipelines use (`groupbyattrs` among them); a collector that references a missing component fails to start outright. Cost: a larger image than either cluster strictly needs.
- **Logs via `filelog` plus a `trace_id` regex, not the OTLP logs SDK.** Applications log to stdout; the agent tails `/var/log/pods` and Grafana's `derivedFields` turns `trace_id=…` into a link to the trace. Cost: correlation depends on a log format convention rather than a structured field, and `transform/logs` currently maps log paths to service names with two hardcoded rules.

## What is not implemented

Stated plainly, because these read as features if you only skim the directory tree:

- **Multi-tenant routing** — [`otel-gateway-multitenant.yaml`](observability-platform/02-gateway-configuration/otel-gateway-multitenant.yaml) is a routing-connector template. The deployed gateway has no routing connector, and Mimir runs with `auth_enabled: false` behind a gateway that injects `X-Scope-OrgID: anonymous`. One tenant, effectively.
- **The dashboard and alert generator chart** — `03-dashboards-and-alerts/helm-chart/` renders `PrometheusRule` objects. No Prometheus Operator CRDs are installed and Mimir's ruler is disabled, so nothing consumes them. The two golden-signal dashboards *are* deployed, as a ConfigMap read by Grafana's sidecar.
- **GitOps** — `04-cluster-gitops-baseline/` contains an Argo CD app-of-apps pointing at a placeholder repo URL. Argo CD is not installed on either cluster. Deployment is `kubectl apply` from the Makefile.
- **Gateway autoscaling** — the HPA is declared (2–10 replicas at 80% CPU) but no metrics-server is installed by this repo, so it has no metric source. The replica count is effectively fixed at 2.
- **Alerting** — no Alertmanager, no notification path. Mimir's alertmanager is disabled.
- **Collector self-monitoring** — the gateway exposes its own metrics on `:8889`, but nothing scrapes them. Refused and dropped spans are invisible.
- **Transport security** — every OTLP hop sets `tls.insecure: true`. The ingest NLB is internal, but the Grafana ALB is internet-facing on plain HTTP with no TLS and no SSO, and both EKS API endpoints have public access enabled. Fine for a sandbox, not for anything else.
- **Terraform state** — local only. No S3 backend, no locking, no CI plan. GitHub Actions builds and pushes images; it does not validate Terraform, render Helm, or lint collector configs.
- **A second workload cluster.** The onboarding contract and per-language templates are written for many clusters and many services; one workload cluster with two services is what runs.

## How to run it

### Prerequisites

- AWS credentials with Admin/PowerUser permissions (`aws configure`). Region is hardcoded to `us-east-1`.
- `kubectl` 1.23+, `terraform` 1.5.0+, `helm` 3.x, `python3`.
- ECR repositories are created by Terraform, so run `make k8s-create` before expecting the image-build workflow to succeed. The workflow needs an `AWS_ROLE_TO_ASSUME` secret for OIDC.

### Cost warning

This provisions real infrastructure. Roughly **$300/month if left running (~$0.40/hour)**, dominated by fixed costs you pay whether or not any telemetry flows:

| Item | Approximate monthly |
|---|---|
| 2× EKS control plane | $146 |
| 2× NAT gateway | $65 + data processing |
| ALB + NLB | ~$35 |
| Observability nodes (2× t3.large spot) | ~$36 |
| Workload nodes (2× t3.medium spot) | ~$18 |
| 5× 10 GiB gp3 | ~$4 |
| S3 | cents at demo volume |

`us-east-1` list prices, excluding data transfer; spot prices vary. **Destroy it when you are done.**

### Deploy

```bash
make k8s-create        # two-stage Terraform apply: infra, then Helm
make k8s-context       # kubeconfig contexts for both clusters
make k8s-deploy-all    # gateway, NLB, collectors, demo apps
```

The two stages are load-bearing and must not be collapsed — see [Decision 6](#6-smaller-decisions-worth-naming). Use `make k8s-create-infra` or `make k8s-create-helm` to re-run a single stage after a partial failure.

### Look at it

```bash
make k8s-dashboards    # port-forward Grafana to http://localhost:3000
make grafana-password  # generated admin password (user: admin)
make k8s-status        # pods on both clusters, plus anything not Running
```

Generate traffic through the demo services:

```bash
ALB=$(kubectl --context apps-workload-cluster-1 get ingress app-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
while true; do curl -s "http://$ALB/product" > /dev/null; sleep 1; done
```

Before changing anything under `helm-values/`:

```bash
make helm-lint         # render the pinned charts locally, no cluster needed
```

### Tear down

```bash
make k8s-destroy
```

S3 buckets are created with `force_destroy = true`, so telemetry data is deleted with them. Afterwards, confirm no load balancers survive — `obs-cluster-grafana`, `obs-cluster-otel-gw`, and `workload-1-app-alb` are created by the Kubernetes manifests rather than by Terraform, and one orphaned by a failed destroy keeps billing.

## What I'd do differently at 10× scale

| Area | Today | At 10× |
|---|---|---|
| Buffering | In-memory only; a gateway outage drops spans | Kafka/MSK between ingestion and processing gateways, so a backend outage costs lag instead of data |
| Backend topology | Loki SingleBinary, Tempo monolithic, Mimir at RF=1 | `loki` distributed, `tempo-distributed`, Mimir at RF=3 with zone-aware replication across three AZs |
| Sampling | 100% of healthy traces kept | Per-tenant budgets, errors and outliers always kept, and a dedicated sampling tier so the gateway is not both stateless router and stateful sampler |
| Tenancy | `auth_enabled: false`, one `anonymous` org | Real `X-Scope-OrgID` per tenant, routing connectors keyed on `tenant.id`, per-tenant retention and limits |
| Cardinality | No attribute allowlist | Enforce a label budget at the gateway and reject high-cardinality attributes before they reach storage |
| Instrumentation config | `HOST_IP` boilerplate in every Deployment | A mutating webhook or shared library chart that injects endpoint, resource attributes, and sampling hints |
| Delivery | `kubectl apply` from a Makefile | Argo CD app-of-apps for real, with the gateway config as a versioned, reviewed artifact |
| Gateway scaling | CPU HPA with no metrics source | metrics-server or KEDA, scaling on exporter queue depth and refused spans rather than CPU |
| Meta-monitoring | Collector self-telemetry unscraped | Scrape `:8889`, alert on refused/dropped spans, and run a synthetic trace canary end to end |
| Terraform | Local state, `-target` staged apply | Remote state with locking, separate root modules per cluster so `-target` is unnecessary, plan-on-PR in CI |
| Regions | Single region | One observability cluster per region; never ship telemetry across a region boundary — egress cost, latency, and data residency all argue against it |
| Security | `tls.insecure` everywhere, HTTP Grafana | mTLS on every OTLP hop, private EKS endpoints, TLS + OIDC on Grafana, per-tenant read isolation |

Longer form, including the sidecar and Kafka-buffer topologies compared side by side: [`architecture-decisions-and-tradeoffs.md`](architecture-decisions-and-tradeoffs.md).

## Screenshots

### Go service — golden signals
![Go Service Dashboard](.github/assets/golang-service-dashboard.png)

### Python service — golden signals
![Python Service Dashboard](.github/assets/python-app-dashboard.png)

### Distributed trace across both services (Tempo)
![Distributed Tracing](.github/assets/grafana-explore-trace.png)

### Log-to-trace correlation (Loki)
![Correlated Logs](.github/assets/grafana-explore-correlation.png)
