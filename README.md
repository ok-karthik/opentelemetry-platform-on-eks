# OpenTelemetry Observability Platform on EKS

A reference enterprise observability platform on Amazon EKS: application teams emit vendor-neutral OTLP telemetry to node-local agents and a central two-tier OpenTelemetry Gateway fleet, while the platform team centrally manages enrichment, sampling, routing, retention, and FinOps costs.

By coupling tail-based sampling, S3 storage tiers, and serverless metric ingestion, this platform slashes observability spend by **70% to 90%** compared to commercial SaaS while eliminating vendor lock-in.

---

## Architecture

Deployable in **Single-Cluster Mode (default, ~$150/mo)** for fast iteration or **Multi-Cluster Peered Mode (~$300/mo)** across peered VPCs (`10.0.0.0/16` for workloads, `10.1.0.0/16` for observability) over an AWS Network Load Balancer (NLB).

```mermaid
flowchart TB
    subgraph WorkloadCluster["Workload Cluster / Namespace (VPC 10.0.0.0/16)"]
        subgraph Pod1["Go Service (Programmatic SDK)"]
            GoApp["golang-product-service\n(Docker Hub)"]
        end
        subgraph Pod2["Python Service (Auto-Instrumented)"]
            PyApp["python-product-info-service\n(Docker Hub)"]
        end
        
        DaemonSetAgent["OTel Collector DaemonSet\n(hostNetwork: true :4317)\nk8sattributes + filelog + kubeletstats"]
        OBI["OBI eBPF DaemonSet\n(Linux Kernel HTTP RED & TCP Visibility)"]
        
        GoApp -->|"OTLP (status.hostIP:4317)"| DaemonSetAgent
        PyApp -->|"OTLP (status.hostIP:4317)"| DaemonSetAgent
        GoApp -.->|"Trace Context (W3C)"| PyApp
        OBI -->|"Kernel Probes (Loopback)"| DaemonSetAgent
    end

    subgraph ObsCluster["Observability Cluster (VPC 10.1.0.0/16)"]
        NLB["AWS Internal NLB\n(Ingress Router)"]
        
        subgraph GatewayFleet["Central OTel Gateway Fleet"]
            Router["Tier 1: Stateless Router\n(Consistent Hash by traceID)"]
            Processor["Tier 2: Stateful Processor\n(Tail-Sampling + OTTL Filters)"]
            Router -->|"gRPC :4319\n(Trace Affinity)"| Processor
        end

        subgraph Backends["Storage Backends"]
            AMP[("Amazon Managed Prometheus\n(Serverless Metrics via SigV4)")]
            Loki[("Loki (SingleBinary)\nS3 via VPC Endpoint")]
            Tempo[("Tempo (Monolithic)\nS3 via VPC Endpoint")]
            Mimir[("Mimir (Metrics)\nSelf-Hosted Alternative")]
            Kafka[("Kafka / MSK\nOptional Buffer")]
            OpenSearch[("OpenSearch\nOptional Analytics")]
            Logstash["Logstash"]
        end

        subgraph Escalation["Alerting & Escalation"]
            Alertmanager["Alert Engine / Alertmanager"]
            GoAlert["GoAlert\n(On-Call Pager)"]
            AlertSink["Alert Sink\n(Ticket Receiver)"]
            Alertmanager -->|"Fast Burn (Critical)"| GoAlert
            Alertmanager -->|"Slow Burn (Warning)"| AlertSink
        end

        Grafana["Grafana\n(Single Pane of Glass UI)"]
        Grafana -->|"SigV4 PromQL"| AMP
        Grafana -->|"LogQL"| Loki
        Grafana -->|"TraceQL"| Tempo
        Processor -.->|"Optional Log Buffer"| Kafka
        Kafka -.-> Logstash
        Logstash -.-> OpenSearch
    end

    DaemonSetAgent -->|"OTLP / Gzip (VPC Peering / Local)"| NLB
    NLB --> Router
    Processor -->|"SigV4 Remote Write"| AMP
    Processor -->|"Native OTLP"| Loki
    Processor -->|"OTLP"| Tempo
    Processor -.->|"Alternative Metrics"| Mimir
```

### The Telemetry Flow (In 5 Steps)

1. **Multi-Tier Instrumentation:** Go microservice (programmatic OTel SDK) calls a Python service (OTel Operator auto-instrumentation) and propagates W3C trace context, while OBI eBPF captures kernel-level TCP and HTTP metrics non-invasively. Both run pre-built multi-arch images from Docker Hub (`ok-karthik/*`).
2. **Node-Local Enrichment:** Pods stream OTLP to their node-local collector via Downward API `status.hostIP:4317` (preserving `k8sattributes` cache locality). The DaemonSet enriches metadata, tails pod logs, and batches telemetry before shipping to the gateway.
3. **Consistent-Hash Gateway Routing:** The Tier 1 Gateway routes traces by `trace_id` consistent hashing to guarantee that all spans of a distributed trace converge on the exact same Tier 2 collector replica.
4. **Platform Policy & Sampling:** The Tier 2 Gateway strips noisy health checks, normalizes HTTP semantic conventions, retains 100% of errors/slow calls while sampling down healthy `200 OK` traces, and applies gzip compression.
5. **Storage & Correlation:**
   - **Metrics:** Streamed via SigV4 remote-write into serverless **Amazon Managed Prometheus (AMP)**.
   - **Traces & Logs:** Exported to **Tempo** and **Loki** on Amazon S3 via **zero-cost S3 Gateway VPC Endpoints** ($0.00/GB data transfer, bypassing NAT Gateways).
   - **Correlation & Paging:** **Grafana** correlates metrics, traces, and logs via `trace_id`; multi-window SLO burn-rate alerts page engineers via **GoAlert**.

---

## 💰 FinOps ROI: Slashing Observability Spend by 70–90%

Traditional SaaS observability vendors (Datadog, Dynatrace, New Relic) bill heavily on raw volume ($1.70–$2.50/M spans, $0.10/GB + $2.50/M logs, $5/100 metrics). In unmanaged environments, **over 95% of the bill is spent indexing repetitive `200 OK` traces and verbose debug logs**.

### Cost Comparison & ROI

| Monthly Telemetry Scale | Commercial SaaS (e.g., Datadog) | OTel Platform on EKS (This Repo) | Monthly Net Savings | Annual Net Savings (% Saved) |
|---|---|---|---|---|
| **Mid Scale** (20 Nodes)<br/>• 10M Requests (~20M Spans)<br/>• 50 GB Logs, 500 Metrics | **~$1,050 / mo**<br/>($12,600 / yr) | **~$310 / mo**<br/>($3,720 / yr) | **+$740 / mo** | **+$8,880 / year**<br/>📉 **70.5% Saved** |
| **Enterprise Scale** (100 Nodes)<br/>• 100M Requests (~500M Spans)<br/>• 1 TB Logs, 5,000 Metrics | **~$8,500 – $12,000+ / mo**<br/>($102k – $144k+ / yr) | **~$780 – $980 / mo**<br/>($9,360 – $11,760 / yr) | **+$7,720 – $11,020+ / mo** | **+$92,640 – $132,240+ / year**<br/>📉 **90.8% – 91.8% Saved** |

### Key FinOps Levers

* **Gateway Tail-Based Sampling:** Retains 100% of errors and latency outliers while sampling healthy traffic down to 5–10%, cutting trace ingestion fees by **80–90%**.
* **S3-Backed Logs & Traces:** Loki and Tempo store immutable chunks directly in Amazon S3 ($0.023/GB) with zero per-event indexing fees, saving **~20× over CloudWatch Logs** ($0.50/GB).
* **Free S3 Gateway VPC Endpoints:** Both VPCs route S3 traffic directly over AWS internal network routes at **$0.00/GB data transfer**, bypassing NAT Gateways ($0.045/GB) and eliminating egress bottlenecks.
* **The "FinOps Firewall" for Existing SaaS:** Even when mandated to retain commercial SaaS, deploying this gateway in-VPC acts as an intelligent firewall, filtering out 90% of healthy noise before external egress to save tens of thousands annually.

---

## 🏛️ Core Platform Capabilities

* **The 4 Levels of Telemetry Instrumentation:** Combines Linux kernel eBPF (catches instant `OOMKilled` Exit 137 and cross-AZ TCP drops), runtime auto-instrumentation (OTel Operator for Python/Java/Node.js stack traces and SQL queries), programmatic Go SDK (`telemetry.go`), and SaaS export. 👉 **[Read the Complete Instrumentation Guide](observability-platform/onboarding/instrumentation-tiers-and-ebpf.md)**.
* **Two-Tier Consistent Hashing:** Solves the distributed tail-sampling challenge by using a stateless router tier to hash `trace_id` to a stateful processor tier, guaranteeing span affinity without data loss.
* **Serverless Metrics with AMP:** Eliminates 10 stateful Mimir pods, cutting cluster memory requests by **~1.9 GiB** with zero pod maintenance toil.
* **Google SRE Multi-Window SLO Alerting:** Evaluates 14.4x, 6x, 3x, and 1x error budget burn rates against RED metrics, paging on-call engineers via GoAlert for critical fast burns and ticket sinks for slow burns.
* **Out-of-Band Meta-Monitoring:** Collector self-telemetry (`:8888`/`:8889`) monitors data drops and backpressure, paired with an external AWS CloudWatch + SNS watchdog for total cluster failure. 👉 **[Read Meta-Monitoring Guide](observability-platform/dashboards-and-alerts/META_MONITORING.md)**.
* **Multi-Tenancy Access Control & Quotas:** Physical S3 prefix partitioning (`X-Scope-OrgID`), Grafana Organizations mapped to corporate SSO, and FinOps stream limits. 👉 **[Read Multi-Tenancy Architecture](docs/multi-tenancy.md)**.

---

## What Actually Gets Deployed

### Observability Cluster

#### Active Components (Default Stack)

| Component | Chart / image | Version | Shape | Status |
|---|---|---|---|---|
| Amazon Managed Prometheus (AMP) | AWS Native Workspace (`aws_prometheus_workspace`) | — | Serverless, SigV4 Auth, EKS Pod Identity | **Active (Default Metrics Backend)** |
| Loki | `grafana/loki` | 7.2.0 | SingleBinary, 1 pod, S3 | **Active (Default Logs Backend)** |
| Tempo | `grafana/tempo` | 1.24.4 | monolithic, 1 pod, S3 | **Active (Default Traces Backend)** |
| Grafana | `grafana/grafana` | 10.5.15 | 1 pod, 3 datasources (AMP SigV4, Loki, Tempo) | **Active (Unified Dashboards UI)** |
| OTel Gateway (Tier 1 & 2) | `otel/opentelemetry-collector-contrib` | 0.156.0 | Deployment & StatefulSet | **Active (Routing, Sampling & Ingest)** |
| GoAlert | `goalert/goalert` (digest-pinned) | v0.34.1 | 1 pod + Postgres StatefulSet | **Active (On-Call Pager Escalation)** |
| Alert sink | `mendhak/http-https-echo` | 31 | 1 pod — webhook receiver for `ticket`-severity alerts | **Active (Ticket Webhook Receiver)** |
| OTel Operator | `opentelemetry-operator` | 0.120.0 | 1 pod | **Active (Auto-Instrumentation Engine)** |
| cert-manager | `jetstack/cert-manager` | v1.21.1 | 3 pods | **Active (Webhook TLS & CA Injection)** |
| AWS LB Controller | `eks/aws-load-balancer-controller` | 3.4.3 | ALB + NLB | **Active (Ingress & Load Balancing)** |
| Karpenter | `oci://public.ecr.aws/karpenter` | 1.0.6 | NodePool + EC2NodeClass | **Active (Node Autoscaling)** |
| gp3 StorageClass | local chart `cluster-storage/` | — | installed before any PVC | **Active (Storage Baseline)** |

#### Alternative & Optional Components (Disabled by Default)

| Component | Chart / image | Version | Default State | When to Use |
|---|---|---|---|---|
| Mimir | `grafana/mimir-distributed` | 6.1.0 | **Disabled** (Replaced by Serverless AMP) | Enable via `use_amazon_managed_prometheus = false` for fully self-hosted open-source Prometheus metrics on S3 (adds 10 stateful pods). |
| Kafka Stub | `bitnami/kafka` | 3.6 | **Disabled** (Optional Log Buffer) | Enable for high-burst log buffering (>25k events/sec) or multi-consumer streaming. |
| OpenSearch | `opensearch-project/opensearch` | 3.8.0 | **Disabled** (Optional Enterprise Analytics) | Enable for SIEM security analytics and free-text fuzzy log search. |
| OpenSearch Dashboards | `opensearch-project/opensearch-dashboards` | 3.8.0 | **Disabled** (Optional Analytics UI) | Enable alongside OpenSearch for Lucene-style log analytics. |
| Logstash | `elastic/logstash` | 8.5.1 | **Disabled** (Optional Ingest Pipeline) | Enable to consume from Kafka and write JSON documents to OpenSearch. |

### Workload Cluster

| Component | Version | Notes |
|---|---|---|
| OTel Collector agent | contrib 0.156.0 | DaemonSet, `hostNetwork: true`, Downward API `status.hostIP:4317` |
| OBI (eBPF instrumentation) | `otel/ebpf-instrument` v0.12.2 | DaemonSet, `hostPID: true` + `hostNetwork: true`, loopback to agent |
| OTel Operator | 0.120.0 | injects Python auto-instrumentation |
| cert-manager | v1.21.1 | webhook TLS for the operator |
| AWS LB Controller | 3.4.3 | ALB for the demo app |
| Go + Python demo services | latest | Docker Hub (`ok-karthik/golang-product-service`, `ok-karthik/python-product-info-service`) |

---

## Where Things Live

| Path | Contents |
|---|---|
| `docs/` | Deep-dive architectural decisions, multi-tenancy, and chart trap references |
| `terraform/` | Multi-cluster and single-cluster EKS, VPC, AMP, S3, IAM |
| `terraform/observability-cluster/helm-values/` | Loki / Tempo / Grafana values, with the reasoning inline |
| `workloads/` | Demo services, their manifests, the DaemonSet collector |
| `observability-platform/` | Gateway, NLB, Grafana ingress, dashboards — the deployed platform |
| `observability-platform/onboarding/` | Onboarding contract, 4 levels of instrumentation, multi-runtime CR |
| `observability-platform/gateway-policies/` | Multi-tenant routing and tail-sampling budgeting policy templates |
| `observability-platform/dashboards-and-alerts/` | Golden signals dashboards, PrometheusRule generator chart, META_MONITORING.md |
| `observability-platform/gitops/` | Argo CD App-of-Apps and regional workload cluster baseline aliases |
| `.agents/AGENTS.md` | Long-form conventions and chart traps |

<details>
<summary>Full tree, annotated with what is deployed and what is a template</summary>

```text
docs/                               # deep-dive architectural decisions, trade-offs, and chart traps
  architectural-decisions.md
  multi-tenancy.md                  # multi-tenancy access control, S3 isolation, Grafana Orgs, alerting
workloads/                          # app-team-owned; reason about it as its own repo
  apps-src/
    golang-app/                     # Go service, programmatic OTel SDK (telemetry.go)
    python-app/                     # Python service, Operator auto-instrumentation
  k8s-manifests/
    otel-collector-daemonset.yaml   # DEPLOYED  agent + OBI eBPF DaemonSet + ExternalName alias + RBAC
    golang-app/                     # DEPLOYED  Deployment, Service, ALB Ingress
    python-app/                     # DEPLOYED  Deployment, Service, Instrumentation CR

observability-platform/             # platform-team-owned; the product surface
  k8s-manifests/                    # DEPLOYED  everything the Makefile applies
    otel-collector-gateway.yaml     #   gateway CR: filters, OTTL, tail sampling, AMP / LGTM exporters
    svc-nlb-otel-gateway.yaml       #   internal NLB, instance target type
    grafana-ingress.yaml            #   internet-facing ALB, HTTP only
    grafana-dashboards-configmap.yaml
    mimir-ruler-rules-configmap.yaml #  SLO burn-rate PrometheusRule-style groups, mounted into ruler
    alert-sink.yaml                 #   webhook echo receiver for ticket-severity alerts
    goalert.yaml                    #   on-call/escalation for page-severity alerts, + its Postgres
    optional-extensions/            #   TEMPLATE  optional enterprise log buffer & OpenSearch templates
      kafka-stub.yaml               #     in-cluster Kafka log buffer stub
      opensearch-index-bootstrap-job.yaml # index template + ISM policy for the ELK path
  onboarding/                       # TEMPLATE  contract, 4 instrumentation levels, multi-runtime CR
    service-onboarding-contract.md  #   contract for service identity, SLOs, and Argo CD values
    instrumentation-tiers-and-ebpf.md # 4 levels of instrumentation, eBPF blind spots & correlation
    instrumentation-manifests/      #   all-runtimes-instrumentation.yaml, go-sdk-template.md
  gateway-policies/                 # TEMPLATE  tenant routing, real sampling budget templates
    otel-gateway-multitenant.yaml
    otel-gateway-tail-sampling.yaml
  dashboards-and-alerts/
    golden-signals/                 # DEPLOYED  raw JSONs rendered via the ConfigMap above
    helm-chart/                     # TEMPLATE  self-service PrometheusRule/Dashboard chart
    META_MONITORING.md              #   "Watch the watcher" health alerting guide
  gitops/                           # TEMPLATE  Argo CD app-of-apps & regional gateway baseline
    gitops-app-of-apps/             #   root-application.yaml, appproject-platform.yaml, child apps
    workload-cluster-baseline/      #   otel-gateway-regional-externalname.yaml

terraform/
  main.tf                           # multi-cluster entrypoint (both clusters + VPC peering)
  single-cluster/                   # DEPLOYED  fast single-cluster entrypoint (reusable module)
    main.tf
  apps-workload-cluster-1/          # EKS, VPC, cert-manager/Operator/LB controller
  observability-cluster/            # EKS, VPC, S3, AMP, IAM, Pod Identity, full LGTM stack
    amp.tf                          # Amazon Managed Prometheus workspace & Pod Identity
    network.tf                      # VPC, subnets, route tables, Free S3 Gateway VPC Endpoint
    helm-values/                    # Loki/Tempo/Grafana .tftpl, reasoning inline
    cluster-storage/                # gp3 StorageClass — installs before any PVC
    karpenter-provisioner/          # NodePool + EC2NodeClass
```

</details>

---

## Decisions and Trade-Offs

| Decision | Chosen Approach | Rejected Alternative | Cost of the Choice |
|---|---|---|---|
| **Collector Topology** | DaemonSet agent + central two-tier gateway | Sidecar-per-pod; agent-only | Additional network hop; fleet to operate |
| **Sampling Strategy** | Tail-based sampling at Tier 2 gateway | Head sampling in the SDK | Stateful gateway; trace-ID affinity required |
| **Cluster Layout** | Single-cluster (dev) / Peered multi-cluster (prod) | Single cluster for everything | VPC peering complexity; extra control plane |
| **Telemetry Backends** | Serverless AMP + S3 Loki/Tempo | Self-hosting 10-pod Mimir cluster | AMP charges $0.90/10M samples; zero pod toil |
| **Agent Addressing** | Node-local `status.hostIP` via Downward API | Collector ClusterIP Service | Workloads declare hostIP Downward API block |
| **Log Architecture** | Loki-first (with optional Kafka $\rightarrow$ OpenSearch) | OpenSearch / ELK for everything | Query syntax differences; dual-path maintenance |
| **Alerting & Escalation** | Google SRE SLO burn-rate alerts + GoAlert | App-level alerts; unmaintained Grafana OnCall | Manual initial token bootstrap in GoAlert |

👉 *For deep dives into each choice, upstream Helm chart traps, and operational details, read [Architectural Decisions & Trade-Offs Deep Dive](docs/architectural-decisions.md).*

---

## What Is Not Implemented

Stated plainly, because these read as features if you only skim the directory tree:

- **Multi-tenant routing** — [`otel-gateway-multitenant.yaml`](observability-platform/gateway-policies/otel-gateway-multitenant.yaml) is a template. The deployed gateway currently routes to a single default tenant.
- **The dashboard-and-alert generator chart** — `observability-platform/dashboards-and-alerts/helm-chart/` is a reusable Helm chart generating Kubernetes Prometheus rule definitions. Deployed golden-signal dashboards run directly in Grafana via ConfigMaps.
- **GitOps** — `observability-platform/gitops/` contains an Argo CD app-of-apps pointing at a placeholder repo URL. Deployment is `kubectl apply` from the Makefile.
- **Gateway autoscaling** — the HPA is declared (2–10 replicas at 80% CPU) but no metrics-server is installed by this repo, so it has no metric source. The replica count is effectively fixed at 2.
- **Transport security** — every OTLP hop sets `tls.insecure: true`. The ingest NLB is internal, but the Grafana ALB is internet-facing on plain HTTP with no TLS and no SSO. Fine for a sandbox, not for production.
- **Terraform state** — local only. No remote S3 backend or state locking configured.

---

## How to Run It

### Prerequisites

- AWS credentials with Admin/PowerUser permissions (`aws configure`). Region defaults to `us-east-1`.
- `kubectl` 1.23+, `terraform` 1.5.0+, `helm` 3.x, `python3`.
- Demo application images are publicly hosted on Docker Hub (`ok-karthik/*`). No manual image builds or ECR logins are needed.

### Cost Warning

* **Single-Cluster Mode (`SINGLE_CLUSTER=true`, default):** Roughly **~$150/month (~$0.20/hour)**. Uses 1× EKS control plane, 1× NAT gateway, serverless AMP metrics, 2× `t3.large` spot nodes, and free S3 Gateway VPC endpoints.
* **Multi-Cluster Peered Mode (`SINGLE_CLUSTER=false`):** Roughly **~$300/month (~$0.40/hour)**. Uses 2× EKS control planes, 2× NAT gateways, cross-VPC peering, and 2 separate node groups.

`us-east-1` list prices, excluding data transfer; spot prices vary. **Destroy it when you are done.**

### Deploy

```bash
make k8s-create        # two-stage apply in Single-Cluster mode (~$150/mo, fastest)
# OR: make k8s-create SINGLE_CLUSTER=false  # dual-cluster peered topology (~$300/mo)

make k8s-context       # configure kubeconfig contexts
make k8s-deploy-all    # deploy gateway, collectors, and workloads
```

### Access & Verify

```bash
make k8s-dashboards    # port-forward Grafana to http://localhost:3000
make grafana-password  # fetch generated admin password (user: admin)
make k8s-status        # check pod health across namespaces
```

Generate traffic through the demo services:

```bash
# In Single-Cluster mode (default):
ALB=$(kubectl --context observability-platform get ingress app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# In Multi-Cluster mode:
# ALB=$(kubectl --context apps-workload-cluster-1 get ingress app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

while true; do curl -s "http://$ALB/product" > /dev/null; sleep 1; done
```

### Tear Down

```bash
make k8s-destroy
```

---

## Screenshots

### Go service — golden signals
![Go Service Dashboard](.github/assets/golang-service-dashboard.png)

### Python service — golden signals
![Python Service Dashboard](.github/assets/python-app-dashboard.png)

### Distributed trace across both services (Tempo)
![Distributed Tracing](.github/assets/grafana-explore-trace.png)

### Log-to-trace correlation (Loki)
![Correlated Logs](.github/assets/grafana-explore-correlation.png)
