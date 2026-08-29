# Architectural Decisions and Technical Deep Dive

This document details the architectural rationale, trade-offs, and design choices implemented in the OpenTelemetry Platform on Amazon EKS.

---

## Summary Matrix

| Decision | Chosen Approach | Rejected Alternative | Cost of the Choice |
|---|---|---|---|
| **Collector Topology** | DaemonSet agent + central two-tier gateway | Sidecar-per-pod; agent-only | Additional network hop; fleet to operate |
| **Sampling Strategy** | Tail-based sampling at Tier 2 gateway | Head sampling in the SDK | Stateful gateway; trace-ID affinity required |
| **Cluster Layout** | Dedicated observability EKS cluster in peered VPC | Single cluster, separate namespace | ~$73/mo extra control plane; VPC peering |
| **Telemetry Backends** | Self-hosted LGTM (S3-backed) | AMP + AMG or commercial SaaS | Managing four stateful open-source systems |
| **Agent Addressing** | Node-local `status.hostIP` via Downward API | Collector ClusterIP Service | Workloads declare hostIP Downward API block |
| **Log Architecture** | Loki-first (with optional Kafka $\rightarrow$ OpenSearch) | OpenSearch / ELK for everything | Query syntax differences; dual-path maintenance |
| **Alerting & Escalation** | Mimir Ruler SLO burn-rate + GoAlert | App-level alerts; unmaintained Grafana OnCall | Manual initial token bootstrap in GoAlert |
| **High Availability & Kafka** | Direct LGTM default; Kafka buffer for >25k/sec | Kafka for every environment | Extra infra & broker maintenance at low scale |
| **GitOps Engine** | Amazon EKS Managed Capability (Argo CD) | Self-hosted Helm Argo CD on worker nodes | Capability hourly rate; offloads Redis & node compute |

---

## Detailed Decisions

### 1. DaemonSet Agent Plus a Central Two-Tier Gateway

**Chosen:** A per-node collector that only enriches, batches, and forwards, feeding a horizontally scaled gateway on a separate cluster that owns all policy.

**Rejected — Sidecar per pod:** Resource cost scales with pod count rather than node count, and a sidecar sees exactly one service, so tail sampling across a distributed trace is impossible.  
**Rejected — Agent-only, exporting straight to backends:** Every node then holds backend credentials, every policy change is a fleet-wide DaemonSet rollout, and backends see N connections instead of a handful.

**What it cost:** An extra hop and its failure mode: if the gateway is down, agents buffer in memory and eventually drop. It also splits debugging across two collector configs, which is why `k8sattributes` enrichment failures are easy to miss (they are silent and partial).

**Why the split is drawn where it is:** Enrichment needs node-local context, so it must run on the node. Sampling needs a whole trace, so it cannot. That single fact determines the architecture.

---

### 2. Tail Sampling at the Gateway (Consistent Hashing)

**Chosen:** `tail_sampling` with a 10s decision window and 10,000 in-flight traces, wired into the traces pipeline: keep all `ERROR` traces, keep everything slower than 2000 ms, and apply a probabilistic policy to the rest.

**Rejected — Head sampling in the SDK:** The decision is made on the first span, before anyone knows whether the request failed or was slow. At 1% head sampling you keep 1% of your errors, which is backwards: the traces worth keeping are the rare ones.

**What it cost:** Tail sampling is stateful — every span of a trace must reach the *same* gateway replica. That forced a two-stage pipeline: Tier 1 (Deployment) with a `loadbalancing` exporter keyed on `traceID`, resolving Tier 2 pods through the Kubernetes API, and Tier 2 (StatefulSet) that receives on 4319 and actually samples.

---

### 3. Cluster Topology: Single-Cluster Default vs. Multi-Cluster Regional Hub

**Chosen:** Support two distinct operational modes, with **Single-Cluster Mode (`SINGLE_CLUSTER=true`, ~$150/mo)** as the recommended default for fast iteration and standard environments, and **Multi-Cluster Peered Mode (`SINGLE_CLUSTER=false`, ~$300/mo)** for regional fleet aggregation.

#### Topology 1: Single-Cluster Mode (Default, ~$150/mo)
![Single-Cluster Architecture](../.github/assets/single_cluster_architecture.png)

#### Why Single-Cluster is the Default (The 80% Case):
- **FinOps Efficiency:** Slashes baseline infrastructure costs by ~50% ($150/mo vs $300/mo) by eliminating an idle second EKS control plane ($73/mo), second NAT gateway ($32/mo), and cross-VPC peering routes.
- **Sub-Millisecond In-Cluster Latency:** OTel DaemonSet agents stream directly to `otel-collector-tier1-router-collector.monitoring.svc.cluster.local:4317` via CoreDNS without traversing an external load balancer.
- **Namespace & Node-Pool Isolation:** Application workloads run in `default` (or `workloads`), while observability backends run in `monitoring`. Teams needing compute isolation use dedicated node pools with taints (`dedicated=monitoring:NoSchedule`).

---

#### Topology 2: Multi-Cluster Peered Mode (~$300/mo)
![Multi-Cluster Architecture](../.github/assets/multi_cluster_architecture.png)

#### Why Large Enterprises Run a Dedicated Observability Cluster ("Why Not Just Node Pools?"):
1. **The "Watching the Watcher" Failure Domain:** If your workload cluster suffers a catastrophic failure (CoreDNS crash, VPC CNI IP exhaustion, etcd compaction lockup, or a broken control plane upgrade), an in-cluster observability stack dies *at the exact moment you need it most*. Alertmanager cannot fire, Grafana is down, and engineers are blind. A separate cluster guarantees telemetry persists during total workload cluster failure.
2. **Control Plane & etcd Blast Radius:** Dedicated node pools isolate EC2 CPU and RAM, but they **cannot** isolate the shared Kubernetes API server, etcd database, or CoreDNS pods. High-throughput telemetry and continuous pod-discovery watches can overwhelm shared control plane resources.
3. **N:1 Regional Fleet Aggregation:** Large enterprises operate 10 to 50+ clusters (Dev, Staging, Prod-US, Prod-EU, PCI-compliant). Deploying redundant Loki/Tempo/AMP instances in every cluster is financially wasteful and operationally unmanageable. A central observability cluster aggregates telemetry across all clusters over an internal NLB.
4. **Security & Audit Isolation (SOC2 / PCI-DSS):** Compliance frameworks mandate that audit logs and system telemetry reside in a locked-down AWS security/monitoring account where application developers and workload pods have zero write/delete permissions.

---

### 4. Storage Architecture: Serverless AMP + S3 Loki/Tempo

**Chosen:** Amazon Managed Prometheus (AMP) for serverless metrics, paired with Grafana Loki and Grafana Tempo backed by Amazon S3 via free S3 Gateway VPC Endpoints.

**Why Serverless AMP over Self-Hosted Mimir:**
- Eliminates 10 stateful Mimir microservice pods (distributor, ingester, querier, ruler, alertmanager, compactor), saving **~1.9 GiB RAM** on worker nodes.
- Zero maintenance: no ring compactions, no etcd coordination, no persistent disk management for metric blocks.
- Authenticates natively via AWS SigV4 through EKS Pod Identity.

*(Note: Self-hosted Mimir remains fully supported as an opt-in alternative via `use_amazon_managed_prometheus = false` for local or non-AWS deployments).*

#### Key Upstream Chart Traps Documented:

| Trap | Symptom / Root Cause | Platform Mitigation |
|---|---|---|
| **Loki `chunksCache`** | Requests 9830Mi RAM by default; unschedulable on demo nodes. | Disabled in `loki.yaml.tftpl`. |
| **Mimir 6.x Ingest Method** | Hardcodes `push_grpc_method_enabled: false` expecting Kafka. | Explicitly enabled `push_grpc_method_enabled: true` in `mimir.yaml.tftpl`. |
| **Tempo Namespacing** | Settings are nested under `tempo:`; top-level `storage:` is ignored. | Values properly nested under `tempo.storage.trace.*`. |
| **cert-manager Webhook** | cert-manager v1.14 webhook fails on Kubernetes 1.35 API server. | Pinned cert-manager v1.21.1 alongside K8s 1.35. |
| **Unpinned Helm Charts** | Charts re-resolve on every apply; upstream schema shifts break clusters. | Every chart pinned in `local.chart_versions` map. |
| **StorageClass Ordering** | With `-parallelism=20`, PVCs hang if StorageClass is not ready. | `cluster-storage/` installs before stateful Helm charts. |

---

### 5. Node-Local Routing via `status.hostIP`

**Chosen:** Workloads resolve their own node's IP through the Downward API and export to `http://$(HOST_IP):4317`. The collector runs `hostNetwork: true` with `dnsPolicy: ClusterFirstWithHostNet`.

**Rejected — The collector's ClusterIP Service:** `k8sattributes` is configured with `filter.node_from_env_var: K8S_NODE_NAME`, which caches only the pods on its own node to keep the API watch cheap at scale. Telemetry arriving from a pod on a *different* node gets no `k8s.*` attributes at all. Routing through the Service round-robins across nodes, so on an N-node cluster roughly (N-1)/N of your telemetry loses its enrichment.

---

### 6. Supporting Architecture Decisions

- **EKS Pod Identity over IRSA:** Trust policy is static (`pods.eks.amazonaws.com`) with no OIDC provider URL to thread through Terraform, allowing IAM roles to be created before the cluster OIDC issuer exists.
- **Two-Stage Terraform Apply:** `make k8s-create` runs an infra-only apply with explicit `-target` flags, then a second apply that installs Helm, avoiding plan-time API server connectivity failures.
- **`otel/opentelemetry-collector-contrib` Pinned Everywhere:** Avoids the slim `opentelemetry-collector-k8s` default which lacks essential processors like `groupbyattrs`.
- **OBI DaemonSet (Kernel eBPF):** Runs as its own privileged DaemonSet forwarding over loopback to the node-local agent, avoiding the need for custom Collector binary builds.

---

### 7. SLO Burn-Rate Alerting in the Observability Layer

**Chosen:** Multi-window, multi-burn-rate SLO alerts ([`mimir-ruler-rules-configmap.yaml`](../observability-platform/k8s-manifests/mimir-ruler-rules-configmap.yaml)) following the Google SRE Workbook pattern: four alerts per service pairing long windows with short windows (14.4x/6x/3x/1x against a 99.5% availability SLO). Fast-burn spikes page on-call via GoAlert; slow-burn budget consumption opens tickets on Alert-Sink.

**Why in the platform layer:** SLIs are emitted by applications, but SLO thresholds, burn-rate windows, and routing policies are platform-owned and should not require application code changes or redeployments.

---

### 8. Loki-First Logging with Optional Kafka/ELK Analytics

**Chosen:** Loki is the default, lightweight, S3-backed log backend. All application and container logs route directly via OTLP (`otlphttp/loki`) into Loki, enabling instant trace-to-log correlation in Grafana. An optional Kafka buffering and Logstash $\rightarrow$ OpenSearch pipeline is fully scaffolded for enterprise environments requiring arbitrary full-text indexing or SIEM analytics.

---

### 9. GoAlert for Incident Escalation

**Chosen:** GoAlert (self-hosted) handles on-call rotations and escalation policies for `page`-severity alerts.

**Rejected — Grafana OnCall:** Self-hosted edition was archived upstream in March 2026.  
**Rejected — SaaS Trials:** Expire after 14–30 days, breaking reproducibility for demo environments.

---

### 10. Single-Pod vs. Distributed HA Scaling & Kafka Buffer Criteria

**Single-Pod vs. Distributed Multi-Pod Topology:**
* **Demo / Medium Workloads (<25,000 events/sec):** Deploys Loki in `SingleBinary`, Tempo in `monolithic`, and Mimir with Replication Factor 1 (`RF=1`). This keeps the base observability cluster footprint compact (~2.2 vCPU / ~6.4 GiB RAM on 2× `t3.large` spot nodes, costing ~$310/mo total).
* **Enterprise High-Availability (>25,000 events/sec):** Scales to `grafana/loki` distributed (3× read, 3× write, compactor), `tempo-distributed` (3× ingester, 2× distributor, 2× querier), and Mimir with **Replication Factor 3 (`RF=3`)** with zone-aware replication across 3 AZs on 6× `m6i.large` spot nodes.

**Throughput & Burst Criteria: When to Add Kafka/MSK:**
* **Direct Gateway Path (< 1.5M events/min or < 90M events/hr):** Horizontally scaled OTel Gateways push directly to LGTM with in-memory retry queues (`sending_queue`). Sub-50ms latency, zero extra infrastructure cost.
* **Kafka Ingestion Tier (> 1.5M – 3.0M+ events/min or > 100M – 200M+ events/hr):** Introduced between Tier 1 and Tier 2 Gateways when any of these conditions occur:
  1. **Extreme Burst Ingestion:** Absorbs 5x–10x sudden surges (flash sales, failovers) without triggering collector `memory_limiter` drops.
  2. **Storage Outage Decoupling:** Provides 24–48 hours of disk-backed lag persistence during backend maintenance or S3 partition issues with **zero data loss**.
  3. **Multi-Consumer Fan-Out:** Streams telemetry simultaneously to Loki, OpenSearch SIEM, and S3 compliance data lakes.

---

### 11. Amazon EKS Managed Capability for Argo CD vs. Self-Hosted Helm

**Chosen:** Amazon EKS Managed Capability for Argo CD (`control-plane-argocd`).

**Rejected — Self-Hosting Argo CD via Helm on EC2 Worker Nodes:**
* Running 5–7 pods (`argocd-server`, `argocd-repo-server`, `argocd-application-controller`, Redis HA with Sentinel, Dex) consumes ~1.5–2.5 vCPUs and ~3–6 GiB of RAM. On AWS, this forces sizing a larger node group just to host the GitOps controller (~$50–$80/month in extra EC2 compute).
* Requires manual operations: patching Argo CD CVEs, configuring Redis HA persistence, handling controller state migrations, and tuning cache sync intervals.

**What it bought:**
* **Zero Worker Node Overhead:** The controller, Redis caching, and UI run in AWS-managed control plane infrastructure outside the cluster with 0 vCPU / 0 MB overhead on worker nodes.
* **Automated Lifecycle & IAM Integration:** AWS manages high availability, patching, and backups, while integrating natively with IAM Identity Center and EKS Access Entries.

---

## Appendix: Architecture Evolution Patterns (From Simple to Global Enterprise)

Below is the incremental architectural progression that explains why this platform evolved from basic sidecars to a dedicated two-tier regional gateway:

### Pattern 1: Sidecar Only -> Direct SaaS
An OTel Collector runs as a sidecar container inside every microservice pod.
* **Pros:** Resource isolation; no intermediate network hops.
* **Cons:** High baseline cost (1 sidecar per pod); Tail-sampling across distributed traces is impossible; Risk of SaaS API rate-limiting.

```mermaid
graph TD
    subgraph Region["AWS Region (us-east-1)"]
        subgraph EKSCluster["EKS Cluster"]
            subgraph PodA["App Pod A"]
                AppA["Microservice A"] -->|Localhost / OTLP| SidecarA["OTel Sidecar"]
            end
            subgraph PodB["App Pod B"]
                AppB["Microservice B"] -->|Localhost / OTLP| SidecarB["OTel Sidecar"]
            end
        end
    end
    SidecarA -->|Export| SaaS["SaaS / Managed Backend"]
    SidecarB -->|Export| SaaS
```

---

### Pattern 2: DaemonSet Only -> Direct SaaS
One OTel Collector runs on every EKS Worker Node as a DaemonSet. All pods on that node send their telemetry to the node's local agent.
* **Pros:** Lower overhead (1 agent per node); Enables host-level and k8s metadata enrichment.
* **Cons:** Tail-sampling across distributed microservices is impossible; Traffic spikes risk node agent OOM crashes.

```mermaid
graph TD
    subgraph Region["AWS Region"]
        subgraph EKSCluster["EKS Cluster"]
            subgraph Node1["EKS Worker Node 1"]
                AppA["App Pod A"] -->|Host IP / OTLP| DSAgent1["OTel DaemonSet"]
                AppB["App Pod B"] -->|Host IP / OTLP| DSAgent1
            end
            subgraph Node2["EKS Worker Node 2"]
                AppC["App Pod C"] -->|Host IP / OTLP| DSAgent2["OTel DaemonSet"]
            end
        end
    end
    DSAgent1 -->|Export| SaaS["SaaS / Managed Backend"]
    DSAgent2 -->|Export| SaaS
```

---

### Pattern 3: DaemonSet -> In-Cluster Gateway -> Backends
DaemonSets act only as lightweight forwarders, sending data to a centralized OTel Gateway running within the *same* EKS cluster.
* **Pros:** Enables cluster-wide tail-sampling; Centralizes API keys; Reduces network egress via batching.
* **Cons:** Gateway memory usage for tail-sampling can compete with app workloads on the same worker nodes.

```mermaid
graph TD
    subgraph Region["AWS Region"]
        subgraph EKSCluster["EKS Cluster"]
            subgraph Nodes["Worker Nodes"]
                AppA["App Pod"] -->|OTLP| DSAgent["OTel DaemonSet"]
            end
            subgraph GatewayNodeGroup["Dedicated Node Group"]
                DSAgent -->|Forward| Gateway["OTel Gateway (Deployment / HPA)"]
            end
        end
    end
    Gateway -->|Batch & Tail-Sample| Backends["Backends (AMP / LGTM / SaaS)"]
```

---

### Pattern 4: DaemonSet -> Dedicated Regional Gateway Cluster (This Repo's Multi-Cluster Topology)
Workload clusters run lightweight DaemonSets, forwarding data over AWS PrivateLink or VPC Peering to a **Dedicated Observability EKS Cluster** in the same region.
* **Pros:** Perfect cross-cluster tail-sampling; Complete isolation of heavy telemetry processing from application workloads; Centralized FinOps cost controls.
* **Cons:** Requires VPC Peering or PrivateLink management; Cross-AZ data transfer considerations.

```mermaid
graph TD
    subgraph Region["AWS Region (us-east-1)"]
        subgraph AppCluster1["App EKS Cluster 1"]
            App1["Apps"] --> DS1["DaemonSet"]
        end
        subgraph AppCluster2["App EKS Cluster 2"]
            App2["Apps"] --> DS2["DaemonSet"]
        end
        subgraph ObsCluster["Dedicated Observability EKS Cluster"]
            NLB["Internal NLB"]
            Gateway["OTel Gateway Fleet (HPA, Consistent Hash)"]
            NLB --> Gateway
        end
        DS1 -->|VPC Peering| NLB
        DS2 -->|VPC Peering| NLB
    end
    Gateway -->|Tail Sample & Route| Backends["Backends (AMP, S3 Loki, Tempo)"]
```

---

### Pattern 5: Enterprise Kafka/MSK Buffer Architecture (High Burst Protection)
At global enterprise scale (>25k–50k events/sec), introduce **Apache Kafka (Amazon MSK)** as a persistent disk buffer between an Ingestion Gateway and a Processing Gateway.
* **Pros:** Zero data loss during backend outages or flash sale spikes; 24–48 hours disk persistence lag buffer; Multi-consumer fan-out to S3 data lakes and SIEMs.
* **Cons:** Additional operational broker management and compute infrastructure.

```mermaid
graph TD
    subgraph Region["AWS Region (us-east-1)"]
        subgraph AppClusters["Workload Clusters"]
            App["Apps"] --> DS["OTel DaemonSet"]
        end
        subgraph ObsVPC["Observability VPC"]
            IngestGateway["Tier 1 Ingestion Gateway (Stateless)"]
            Kafka[("Amazon MSK / Kafka Buffer (Disk Persistence)")]
            ProcessGateway["Tier 2 Processing Gateway (Stateful Tail Sampling)"]
            
            DS --> IngestGateway
            IngestGateway -->|Produce| Kafka
            Kafka -->|Consume| ProcessGateway
        end
    end
    ProcessGateway --> Backends["Observability Backends"]
```



