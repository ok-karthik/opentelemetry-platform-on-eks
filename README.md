# OpenTelemetry Observability Platform on EKS

A working multi-cluster observability platform on Amazon EKS: application teams emit OTLP and get traces, metrics, and logs correlated in Grafana, while the platform team owns enrichment, sampling, routing, retention, and cost in one place instead of in every service.

The problem it solves is ownership. Without a platform layer, every team picks its own agent, its own sampling rate, and its own backend, and the observability bill grows linearly with traffic while nobody can follow a request across two services. Here, applications declare *what* they are (`service.name`, `team`, `deployment.environment`) and the platform decides *where telemetry goes, what survives sampling, and how long it is kept*.

Everything below is deployed by the code in this repository. Where something is a template rather than a running component, it is marked **not implemented** — see [What is not implemented](#what-is-not-implemented).

---

## Enterprise Architecture Patterns

This platform has been upgraded to implement enterprise-grade observability patterns:

1. **eBPF Zero-Code Instrumentation (OBI):** A dedicated `obi-agent` DaemonSet uses [OpenTelemetry eBPF Instrumentation](https://opentelemetry.io/docs/zero-code/obi/) to natively capture RED (Rate, Errors, Duration) metrics and traces from the kernel, with no SDK in the target process. OBI is a separate upstream project from the Collector — there is no `obi` receiver in the `opentelemetry-collector-contrib` image, so it cannot be configured as a receiver on `otel-collector-agent` without building a custom Collector binary via OCB. It runs as its own process instead, forwarding OTLP to the node-local Collector over loopback so its telemetry still gets `k8sattributes`-equivalent enrichment (self-attached, since connection-based pod association can't see loopback traffic), `team` tagging, and gateway routing.
2. **Two-Tier Gateway (Consistent Hashing):** The central OTel Gateway is split into two tiers:
   - **Tier 1 (Router):** A Deployment that hashes trace traffic by `traceID` and routes it.
   - **Tier 2 (Processor):** A StatefulSet that receives the hash-aligned traces. This guarantees every span for a trace lands on the exact same replica, enabling accurate **tail-based sampling**.
3. **Log Architecture (Loki-First + Optional Kafka/ELK Analytics):** All container and application logs are ingested natively into **Loki** over OTLP (`otlphttp/loki`), providing lightweight, S3-backed storage and sub-second trace-to-log correlation in Grafana. The repository also includes a fully configured optional enterprise extension with Kafka buffering and Logstash $\rightarrow$ OpenSearch (with ISM rollover policies and attribute flattening) for arbitrary free-text indexing. See [Decision 8](#8-elk-alongside-loki-not-instead-of-it).
4. **Network & Latency Optimization (OTLP Compression & Topology Routing):** Ingestion pipelines across the DaemonSet agent and Gateway tiers enforce `compression: gzip` on OTLP data streams (cutting cross-AZ and cross-cluster egress bandwidth by ~80%) and enable Kubernetes Topology Aware Routing (`service.kubernetes.io/topology-mode: Auto`) on the Ingestion NLB.
5. **SLO Burn-Rate Alerting:** Mimir's ruler and Alertmanager run multi-window, multi-burn-rate SLO alerts (the Google SRE Workbook pattern) against both demo services' RED metrics — a fast 5xx spike pages within minutes, a slow leak opens a ticket instead. `page`-severity alerts route to **GoAlert**, a self-hosted on-call/escalation tool — Alertmanager can route and dedupe, but has no concept of an on-call rotation or an escalation chain. See [Decision 7](#7-slo-burn-rate-alerts-in-the-observability-layer-not-the-app) and [Decision 9](#9-goalert-over-grafana-oncall-or-a-paid-trial).
6. **Meta-Monitoring (Monitoring the Monitoring):** The platform instruments itself. Collectors expose their own internal Prometheus metrics on `:8888` and `:8889` which are scraped and fed into Mimir. Mimir evaluates alerts on `otelcol_receiver_refused_*` (backpressure), `otelcol_processor_dropped_*` (data loss), and flatline detection (silent failures). A decoupled external CloudWatch alarm combined with an SNS pager topic guarantees alerts fire even if the entire EKS observability cluster goes down. See [META_MONITORING.md](observability-platform/03-dashboards-and-alerts/META_MONITORING.md).

## Architecture

```mermaid
flowchart TD
    subgraph "Workload Cluster (App Team)"
        App1[App Pods]
        App2[App Pods]
        Agent[OTel Agent DaemonSet]
        OBI[OBI DaemonSet\neBPF Zero-Code Instrumentation]

        App1 -->|OTLP: SDK traces/logs| Agent
        App2 -->|OTLP: SDK traces/logs| Agent
        App1 -.->|eBPF probes, no SDK| OBI
        App2 -.->|eBPF probes, no SDK| OBI
        OBI -->|OTLP over loopback: RED metrics & traces| Agent
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
| Mimir | `grafana/mimir-distributed` | 6.1.0 | 10 pods, 1 replica each, S3 (incl. ruler + alertmanager) |
| Grafana | `grafana/grafana` | 10.5.15 | 1 pod, 3 datasources |
| OTel Gateway (Tier 1 & 2) | `otel/opentelemetry-collector-contrib` | 0.156.0 | Deployment & StatefulSet |
| Kafka Stub | `bitnami/kafka` | 3.6 | 1 pod |
| OpenSearch | `opensearch-project/opensearch` | 3.8.0 | 1 pod (`singleNode`), security plugin disabled, gp3 PVC |
| OpenSearch Dashboards | `opensearch-project/opensearch-dashboards` | 3.8.0 | 1 pod |
| Logstash | `elastic/logstash` | 8.5.1 | 1 pod, Kafka → OpenSearch |
| GoAlert | `goalert/goalert` (digest-pinned) | v0.34.1 | 1 pod + Postgres StatefulSet |
| Alert sink | `mendhak/http-https-echo` | 31 | 1 pod — webhook receiver for `ticket`-severity alerts |
| OTel Operator | `opentelemetry-operator` | 0.120.0 | 1 pod |
| cert-manager | `jetstack/cert-manager` | v1.21.1 | 3 pods |
| AWS LB Controller | `eks/aws-load-balancer-controller` | 3.4.3 | ALB + NLB |
| Karpenter | `oci://public.ecr.aws/karpenter` | 1.0.6 | NodePool + EC2NodeClass |
| gp3 StorageClass | local chart `cluster-storage/` | — | installed before any PVC |

Mimir runs distributor, ingester, querier, query-frontend, query-scheduler, store-gateway, compactor, gateway, ruler, and alertmanager — one replica each. Overrides-exporter, rollout-operator, MinIO, and the bundled Kafka are disabled.

Node group: 2× `t3.large` spot (min 2, max 6), plus Karpenter for burst. Measured request footprint of the trimmed stack is ~2.2 vCPU / ~6.4 GiB.

### Workload cluster

| Component | Version | Notes |
|---|---|---|
| OTel Collector agent | contrib 0.156.0 | DaemonSet, `hostNetwork: true` |
| OBI (eBPF instrumentation) | `otel/ebpf-instrument` v0.12.2 | DaemonSet, `hostPID: true` + `hostNetwork: true`, forwards to the agent over loopback |
| OTel Operator | 0.120.0 | injects Python auto-instrumentation |
| cert-manager | v1.21.1 | webhook TLS for the operator |
| AWS LB Controller | 3.4.3 | ALB for the demo app |
| Go + Python demo services | — | built and pushed to ECR by GitHub Actions |

Node group: 2× `t3.medium` spot (min 1, max 4). No Karpenter — two app pods and a DaemonSet fit a single node group.

### AWS

Five S3 buckets (Loki, Tempo, Mimir blocks/ruler/alertmanager). The alertmanager bucket holds Alertmanager's runtime state (silences, notification log); the ruler bucket is provisioned but unused — Mimir's ruler reads SLO rule groups from a mounted ConfigMap instead (see [Decision 7](#7-slo-burn-rate-alerts-in-the-observability-layer-not-the-app)). One IAM role reached through **EKS Pod Identity** associations, one NAT gateway per VPC, one internal NLB for OTLP ingest, one internet-facing ALB for Grafana, five 10 GiB gp3 volumes, one 1 GiB gp3 volume for Alertmanager, one 10 GiB gp3 volume for OpenSearch, one 5 GiB gp3 volume for GoAlert's Postgres. ECR repositories for both service images. CI authenticates to AWS via GitHub OIDC, not static keys.

### Where things live

| Path | Contents |
|---|---|
| `terraform/` | Both clusters, VPC peering, AWS external Meta-Monitoring, S3, IAM |
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
    otel-collector-daemonset.yaml   # DEPLOYED  agent + OBI eBPF DaemonSet + ExternalName alias + RBAC
    golang-app/                     # DEPLOYED  Deployment, Service, ALB Ingress
    python-app/                     # DEPLOYED  Deployment, Service, Instrumentation CR

observability-platform/             # platform-team-owned; the product surface
  k8s-manifests/                    # DEPLOYED  everything the Makefile applies
    otel-collector-gateway.yaml     #   gateway CR: filters, OTTL, tail sampling, exporters
    svc-nlb-otel-gateway.yaml       #   internal NLB, instance target type
    grafana-ingress.yaml            #   internet-facing ALB, HTTP only
    grafana-dashboards-configmap.yaml
    mimir-ruler-rules-configmap.yaml #  SLO burn-rate PrometheusRule-style groups, mounted into the ruler
    alert-sink.yaml                 #   webhook echo receiver for ticket-severity alerts
    goalert.yaml                    #   on-call/escalation for page-severity alerts, + its Postgres
    opensearch-index-bootstrap-job.yaml #  index template + ISM policy for the ELK path
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

**"Why not one cluster with a tainted node pool for observability instead?"** That's a legitimate cheaper design for a single-account, single-team setup, and it solves the *scheduling* half of the problem: taints keep Mimir/Loki/Tempo off the nodes application pods land on. It does not solve the other two halves this repo is built to demonstrate. First, blast radius: a tainted node pool is still one API server, one control-plane upgrade, one IAM boundary, and one bad `NetworkPolicy` or overly broad RBAC role away from a workload identity reaching the observability stack directly — the isolation is a scheduling hint, not a security boundary, whereas VPC peering plus per-cluster IAM is. Second, and more concretely for this repo: node pools don't need a routable network path crossing a trust boundary, so they don't exercise `nlb-target-type: instance`, asymmetric-return-path debugging, or cross-VPC DNS — which is exactly the AWS networking depth this project is meant to evidence. At real scale (multiple app teams sharing one observability platform, or a compliance boundary between them) two clusters is the standard answer for the same reason two clusters is standard here: taints are cheaper *isolation-of-scheduling*; separate clusters are actual *isolation-of-blast-radius*. They're solving different problems, not competing for the same budget line.

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
- **OBI runs as its own DaemonSet, not a Collector receiver.** OBI (eBPF zero-code instrumentation) and the OTel Collector are separate upstream projects; the `obi` receiver only exists in a custom Collector binary built with OCB, not in `opentelemetry-collector-contrib`. Cost: a second privileged, host-PID DaemonSet to run, and OBI's telemetry gets its own `k8s.*` decoration (`OTEL_EBPF_KUBE_METADATA_ENABLE`) rather than the agent's `k8sattributes`, because it reaches the agent over loopback where the client-IP-based pod association the agent relies on elsewhere has nothing to match against.

### 7. SLO burn-rate alerts in the observability layer, not the app

**Chosen.** Multi-window, multi-burn-rate SLO alerts ([`mimir-ruler-rules-configmap.yaml`](observability-platform/k8s-manifests/mimir-ruler-rules-configmap.yaml)) — the Google SRE Workbook pattern: four alerts per service pairing a long window with a short one, at burn rates of 14.4x/6x/3x/1x against a 99.5% availability SLO, so a real outage pages within minutes and a slow leak opens a ticket instead of paging at 3 a.m. Mimir's ruler evaluates them against the RED metrics both services already emit (`http_server_duration_milliseconds_count` for Go, `http_server_request_duration_seconds_count` for Python — see the golden-signal dashboards for why the names differ) and its Alertmanager routes firing alerts to a receiver.

**Why the observability layer and not application code.** The SLI is whatever the app already emits — a request duration histogram, a status code — but the SLO target, the burn-rate math, and the alert routing are policy decisions that a platform team owns centrally and can change without redeploying a service. Baking a burn-rate threshold into `golang-product-service`'s source would mean every SLO revision is a code change and a redeploy, and would leave every other current or future service with no SLO at all.

**What it cost.** Mimir's `s3` ruler backend only accepts rule groups pushed through a config API (`mimirtool`), which would mean SLO changes bypass `git`/`kubectl apply`. Rules are on `local` ruler storage instead — read from a ConfigMap mounted at `/var/mimir-ruler-rules/anonymous/` — trading the config API's ability to create/delete rules at runtime (unused here) for rules that are versioned and diffable like everything else in this repo. Alertmanager has no per-tenant config pushed either, so `alertmanager.fallbackConfig` in [`mimir.yaml.tftpl`](terraform/observability-cluster/helm-values/mimir.yaml.tftpl) is what actually routes every alert here — production would push a real per-tenant config instead.

**Honest caveat.** `ticket`-severity alerts route to `alert-sink` ([`alert-sink.yaml`](observability-platform/k8s-manifests/alert-sink.yaml)), a request-echoing container — verify one with `kubectl logs -n monitoring -l app=alert-sink`, not by checking a phone. `page`-severity alerts route to GoAlert, which is real but needs a one-time manual bootstrap (an admin user, an escalation policy, an integration key — none of which are expressible as static YAML); see [Decision 9](#9-goalert-over-grafana-oncall-or-a-paid-trial) and the bootstrap steps at the bottom of [`goalert.yaml`](observability-platform/k8s-manifests/goalert.yaml).

### 8. ELK alongside Loki, not instead of it

**Chosen.** A second, purpose-different log pipeline: the gateway's `kafka/logs` exporter → Kafka → Logstash → OpenSearch, running in parallel to the existing OTLP-to-Loki path, both fed from the same `logs` pipeline in [`otel-collector-gateway.yaml`](observability-platform/k8s-manifests/otel-collector-gateway.yaml).

**Why not just Loki, which already works.** Loki is the right tool for this repo's golden-path use case — correlating one service's logs with its traces when you already know the service, the time range, and roughly what you're looking for — and nothing here replaces that. What Loki explicitly doesn't do well: free-text search without knowing labels first (Loki indexes labels, not log bodies; LogQL line-filters scan matching chunks, which doesn't scale to "find this string across 30 days" the way an inverted index does), rich aggregation over fields you didn't pre-declare as labels (Loki deliberately discourages high-cardinality labels — that's Elasticsearch/OpenSearch's job, not a Loki gap to work around), and Grok parsing for log formats you don't control the shape of. This repo's own two services don't actually need that last one — their logs are already clean and structured — which is the honest reason this is a *second* pipeline demonstrating real ELK operational surface, not a load-bearing part of this platform's log story.

**What it cost.** A second stateful backend (OpenSearch, single-node, security plugin disabled — same "not implemented" transport-security trade-off the rest of this platform already makes explicitly) and a Logstash pipeline that has to do real work: OTLP's typed-attribute-union structure (`{"key": ..., "value": {"stringValue": ...}}` arrays) doesn't index usefully as-is, so [`logstash.yaml.tftpl`](terraform/observability-cluster/helm-values/logstash.yaml.tftpl) splits each batch down to one event per log record and flattens both resource- and record-level attributes into plain fields before OpenSearch ever sees them. The exporter's encoding had to move off its default (`otlp_proto`, binary) to `otlp_json` specifically so Logstash's stock `json` codec could read it — the collector's default would have put unreadable bytes on the topic with no error anywhere.

**The actual index-management story** — [`opensearch-index-bootstrap-job.yaml`](observability-platform/k8s-manifests/opensearch-index-bootstrap-job.yaml): an explicit index template (`dynamic: false` — known fields get real types and stay aggregatable, an unanticipated field is stored and ignored rather than failing every document behind it, which is what `dynamic: strict` would do untested), one primary shard with zero replicas (right-sized for a single node and this log volume, not a forgotten default), and an ISM policy — OpenSearch's name for what Elasticsearch calls ILM — that rolls the write alias over by size or age and deletes generations past 7 days, matching the retention every other backend in this platform already uses.

### 9. GoAlert over Grafana OnCall or a paid trial

**Chosen.** GoAlert (self-hosted, [`goalert.yaml`](observability-platform/k8s-manifests/goalert.yaml)) as the receiver for `page`-severity burn-rate alerts — real on-call scheduling, rotations, and escalation policies, which Alertmanager's routing tree has no concept of on its own.

**Rejected — Grafana OnCall.** The obvious first choice given this platform is otherwise 100% Grafana Labs OSS (Loki/Tempo/Mimir/Grafana) — same vendor ecosystem, same operational model. Checked live rather than assumed: Grafana OnCall's self-hosted edition entered maintenance mode 2025-03-11 and was archived 2026-03-24. Dead as of this writing; re-verify before reconsidering it.

**Rejected — OneUptime and similar all-in-one platforms.** These try to *be* the observability platform (their own metrics/logs/tracing/status-page stack), not sit downstream of one. Adding one here would compete with the LGTM stack already running, not complement it.

**Rejected — a PagerDuty/Opsgenie/incident.io free trial.** A real trade-off, not dismissed reflexively: a trial wins on name recognition an interviewer needs no explanation for, and none of GoAlert/OneUptime/Keep appear in job-posting data as a named tool either — unlike the OpenTelemetry-vs-Beyla/Odigos comparison elsewhere in this README, tool-name recognition doesn't settle this one. What does: a trial expires. Someone cloning this repo and running `make k8s-create-helm` months later would hit a dead integration pointing at an expired account, which damages exactly the "this is a real, working demo" property the rest of this README is built to earn. A resume bullet grounded in real work experience doesn't have that problem; a from-scratch portfolio repo does.

**What it cost.** GoAlert needs its own Postgres (a StatefulSet this repo didn't otherwise need — every other backend here is either S3-native or, for OpenSearch, local-disk) and a genuinely manual bootstrap: an admin user and an escalation-policy integration key are account state, not config, and GoAlert has no declarative way to create either. It also doesn't publish numbered version tags to Docker Hub past 2023 even though GitHub Releases continues (v0.34.1, Oct 2025) — the image below is pinned by digest instead of tag, with the corresponding version noted, rather than either fabricating a tag that doesn't exist or falling back to unpinned `latest`.

## What is not implemented

Stated plainly, because these read as features if you only skim the directory tree:

- **Multi-tenant routing** — [`otel-gateway-multitenant.yaml`](observability-platform/02-gateway-configuration/otel-gateway-multitenant.yaml) is a routing-connector template. The deployed gateway has no routing connector, and Mimir runs with `auth_enabled: false` behind a gateway that injects `X-Scope-OrgID: anonymous`. One tenant, effectively.
- **The dashboard-and-alert generator chart** — `03-dashboards-and-alerts/helm-chart/` renders Kubernetes `PrometheusRule` CRD objects. No Prometheus Operator CRDs are installed on either cluster, and Mimir's ruler does not watch `PrometheusRule` resources at all — it reads rule groups from its own `ruler_storage` backend (see [Decision 7](#7-slo-burn-rate-alerts-in-the-observability-layer-not-the-app)). Nothing consumes what this chart renders; the two golden-signal dashboards *are* deployed, as a ConfigMap read by Grafana's sidecar.
- **GitOps** — `04-cluster-gitops-baseline/` contains an Argo CD app-of-apps pointing at a placeholder repo URL. Argo CD is not installed on either cluster. Deployment is `kubectl apply` from the Makefile.
- **Gateway autoscaling** — the HPA is declared (2–10 replicas at 80% CPU) but no metrics-server is installed by this repo, so it has no metric source. The replica count is effectively fixed at 2.
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
| Meta-monitoring | Collector self-telemetry scraped by Mimir, alerts on refused/dropped spans, absent metric data loss, and decoupled external Watchdog | Synthetic trace canary end to end |
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
