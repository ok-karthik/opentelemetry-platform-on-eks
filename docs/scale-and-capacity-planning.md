# Scale and Capacity Planning: 2K to 200K QPS

This document defines the mathematical modeling, node density, collector sizing, and AWS infrastructure capacity required to scale this OpenTelemetry platform from **2,000 App QPS** to **200,000 App QPS** (~2.4 million telemetry events/second).

---

## 1. Workload Modeling & Telemetry Multipliers

In distributed microservice architectures, incoming HTTP requests trigger downstream database calls, RPCs, cache checks, and log statements. We model traffic using standard enterprise production multipliers:

$$\mathbf{1\text{ Application QPS}} \approx \mathbf{8\text{ Spans}} + \mathbf{2\text{ Container Logs}} + \mathbf{2\text{ Metric Data Points}} \approx \mathbf{12\text{ Telemetry Events/sec}}$$

| Scale Tier | App QPS | Tracing Spans/s | Container Logs/s | Metrics Data Points/s | Total Telemetry Events/s | Compressed OTLP Network Egress |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **2K QPS** | 2,000 | 16,000 / s | 4,000 / s | 4,000 / s | **24,000 / s** | ~2.5 MB/s (~20 Mbps) |
| **5K QPS** | 5,000 | 40,000 / s | 10,000 / s | 10,000 / s | **60,000 / s** | ~6.2 MB/s (~50 Mbps) |
| **10K QPS** | 10,000 | 80,000 / s | 20,000 / s | 20,000 / s | **120,000 / s** | ~12.5 MB/s (~100 Mbps) |
| **50K QPS** | 50,000 | 400,000 / s | 100,000 / s | 100,000 / s | **600,000 / s** | ~62.5 MB/s (~500 Mbps) |
| **100K QPS** | 100,000 | 800,000 / s | 200,000 / s | 200,000 / s | **1,200,000 / s** | ~125 MB/s (~1 Gbps) |
| **200K QPS** | 200,000 | 1,600,000 / s | 400,000 / s | 400,000 / s | **2,400,000 / s** | ~250 MB/s (~2 Gbps) |

---

## 2. Workload Pod Density & Node DaemonSet Sizing (Tier 1)

### EKS Worker Node Density
* **AWS VPC CNI Pod Limits:** Standard EKS nodes (e.g. `m5.2xlarge` or `c6i.4xlarge`) run between **30 and 60 application pods per node** under normal operating conditions (up to 110 with VPC CNI prefix delegation).
* **Throughput Per Worker Node:** A typical worker node running 40 microservice pods handles between **1,000 and 3,000 App QPS**.
* **Linear Scaling Reality:** Because the OTel Agent runs as a **DaemonSet** (`mode: daemonset`), each agent pod only processes telemetry from the pods co-located on its *own physical node*. As the cluster scales from 5 to 200 nodes, the per-pod workload on the DaemonSet remains constant.

### Tier 1 DaemonSet Resource Allocation

| Node App Throughput | Inbound Events / Node | DaemonSet CPU (Req / Limit) | DaemonSet RAM (Req / Limit) | Go Runtime Memory Tuning | Batch Processor Configuration |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **< 1,000 QPS** | < 12,000 / s | **100m / 300m** | **192Mi / 384Mi** | `GOMEMLIMIT=300MiB`, `GOGC=80` | `send_batch_size: 4096`, `timeout: 500ms` |
| **1,000 – 3,000 QPS** | 12K – 36K / s | **250m / 600m** | **256Mi / 512Mi** | `GOMEMLIMIT=400MiB`, `GOGC=80` | `send_batch_size: 4096`, `timeout: 500ms` |
| **3,000 – 6,000 QPS** | 36K – 72K / s | **500m / 1200m** | **512Mi / 1024Mi** | `GOMEMLIMIT=800MiB`, `GOGC=80` | `send_batch_size: 8192`, `timeout: 250ms` |

---

## 3. End-to-End Cluster Capacity Matrix (2K to 200K QPS)

The table below outlines pod counts and compute requirements across all platform tiers:

| Component | 2K QPS | 5K QPS | 10K QPS | 50K QPS | 100K QPS | 200K QPS |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Workload Worker Nodes** (`m5.2xlarge`) | 4 - 6 nodes | 8 - 12 nodes | 15 - 20 nodes | 50 - 75 nodes | 100 - 150 nodes | 200 - 300 nodes |
| **Total Workload Pods** | ~150 | ~350 | ~700 | ~3,000 | ~6,000 | ~12,000 |
| **Tier 1 DaemonSet Fleet** | 4 - 6 pods | 8 - 12 pods | 15 - 20 pods | 50 - 75 pods | 100 - 150 pods | 200 - 300 pods |
| **Tier 2 Routers** (2 vCPU / 256 MiB) | 2 pods | 3 pods | 5 - 6 pods | 16 - 20 pods | 30 - 40 pods | 60 - 80 pods |
| **Tier 3 Processors** (4 vCPU / 1 GiB) | 3 pods | 3 pods | 6 - 8 pods | 20 - 25 pods | 40 - 50 pods | 80 - 100 pods |
| **Spike Buffer (Kafka / MSK)** | Direct (None) | Direct (None) | Optional | **Required** (3 brokers) | **Required** (6 brokers) | **Required** (9+ brokers) |
| **Tempo Ingesters** (`r6i.2xlarge`) | 2 pods | 2 pods | 3 pods | 8 pods | 14 pods | 26 pods |
| **Loki Ingesters** (`r6i.2xlarge`) | 2 pods | 2 pods | 3 pods | 6 pods | 10 pods | 18 pods |
| **Metrics (AMP vs Mimir)** | AMP Serverless | AMP Serverless | AMP Serverless | Mimir (10 ingesters) | Mimir (18 ingesters) | Mimir (32 ingesters) |

---

## 4. Operational Optimizations & Tuning Guidelines

### A. Memory Limits & Go Runtime Thrashing (`GOMEMLIMIT`)
In Go-based runtimes like the OpenTelemetry Collector, standard garbage collection triggers only when heap allocations double (`GOGC=100`). Under sudden telemetry spikes, memory allocations outrun GC cycles, causing the Linux kernel to terminate the collector via **Exit 137 (`OOMKilled`)**.

**Platform Standard:**
Always configure `GOMEMLIMIT` to approximately **80% of the container memory limit**, and tune `GOGC=80` to trigger collection earlier:
```yaml
resources:
  limits:
    memory: 384Mi
env:
  - name: GOMEMLIMIT
    value: "300MiB"
  - name: GOGC
    value: "80"
```

### B. Batching Processor Sizing
Flushing telemetry in small increments saturates gRPC connections and causes excessive syscall overhead. The platform tunes the `batch` processor with:
```yaml
processors:
  batch:
    send_batch_size: 4096      # Triggers flush when 4096 spans/logs/metrics accumulate
    send_batch_max_size: 8192  # Hard limit on batch payload
    timeout: 500ms             # Max wait window before exporting partial batch
```
This configuration balances low delivery latency with maximum gzip compression efficiency.

### C. Topology Aware Routing (TAR) for Inter-AZ Cost Elimination
AWS charges **$0.01 per GB in each direction** when network traffic crosses Availability Zones ($0.02/GB round-trip). At 100K QPS, unrouted telemetry costs over **$14,000/month** in cross-AZ network transfer alone.

To eliminate this tax, configure Kubernetes Topology Aware Routing on the Tier 2 Router Service:
```yaml
service:
  trafficDistribution: PreferSameZone
```
This forces Tier 1 DaemonSets to forward telemetry exclusively to Tier 2 Routers residing within the same Availability Zone.

### D. Buffer Architecture at > 25,000 QPS
Direct gRPC export from Tier 3 Processors to backend ingesters (Tempo/Loki/Mimir) is safe below 25K QPS. Above 25K QPS:
* Backend restarts or S3 multi-part upload pauses cause upstream backpressure that exhausts collector memory.
* Deploy an intermediate Kafka/MSK buffer cluster ([`kafka-stub.yaml`](../observability-platform/optional-extensions/kafka-stub.yaml)) to decouple real-time ingestion from backend persistence.
