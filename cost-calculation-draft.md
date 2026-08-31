Scaling your observability pipeline from 20K to 200K application Requests Per Second (QPS) requires exact capacity planning. In a microservices architecture, a single application request often fans out into 6 to 10 OpenTelemetry spans and multiple logs.

For these calculations, we assume an industry standard multiplier: **1 App QPS = 8 Spans + 2 Logs (10 telemetry events per second)**. At 200K QPS, your cluster will generate around 2,000,000 telemetry events per second.

Here is the exact hardware sizing and AWS cloud cost breakdown to support this architecture.

## 1. OTel Tier 2 (Routers) & Tier 3 (Processors) Sizing

* **Tier 2 Routers (`Deployment`):** These are stateless and CPU-bound. Their only job is parsing the trace ID and calculating the consistent hash. One modern CPU core can route roughly 15,000 to 20,000 spans per second. Pod sizing recommendation: **2 vCPU / 2 GiB RAM**.
* **Tier 3 Processors (`StatefulSet`):** These are highly memory-bound. To perform tail sampling, they must buffer spans in memory for 15–30 seconds waiting for the trace to complete. Pod sizing recommendation: **4 vCPU / 12 GiB RAM**.

| App QPS | Telemetry Rate (Spans/s) | Tier 2 Routers (2 vCPU / 2GB) | Tier 3 Processors (4 vCPU / 12GB) |
| --- | --- | --- | --- |
| **20K** | ~160,000 / sec | 6 - 8 pods | 8 - 12 pods |
| **50K** | ~400,000 / sec | 12 - 16 pods | 20 - 25 pods |
| **100K** | ~800,000 / sec | 25 - 30 pods | 40 - 50 pods |
| **200K** | ~1,600,000 / sec | 45 - 55 pods | 80 - 100 pods |

---

## 2. Dedicated EKS Node Pool (Tempo & Loki) Sizing & Cost

Grafana Tempo and Loki Ingesters require high-memory instances with fast local NVMe storage to manage the Write-Ahead Log (WAL) before flushing to S3.

An ideal AWS instance for this is the **`r6gd.2xlarge`** (8 vCPU, 64 GB RAM, local NVMe SSD) or standard **`r6i.2xlarge`** which costs roughly **$367.92/month** on-demand in us-east-1.

| App QPS | Tempo/Loki Node Count | Total vCPU / RAM | Est. EC2 Cost (Monthly) |
| --- | --- | --- | --- |
| **20K** | 4 nodes (`r6i.2xlarge`) | 32 vCPU / 256 GB | ~$1,470 |
| **50K** | 8 nodes (`r6i.2xlarge`) | 64 vCPU / 512 GB | ~$2,940 |
| **100K** | 16 nodes (`r6i.2xlarge`) | 128 vCPU / 1 TB | ~$5,880 |
| **200K** | 30 nodes (`r6i.2xlarge`) | 240 vCPU / 1.9 TB | ~$11,030 |

*(Note: Utilizing Spot instances or Compute Savings Plans can cut this compute bill by up to 55%).*

---

## 3. Hidden AWS Infrastructure Costs (The Real Bill)

At hyper-scale, compute is the cheapest part of observability. The true cost lies in network transfer, managed metrics, and storage API calls.

### A. AWS Inter-AZ Data Transfer (The Silent Killer)

AWS charges **$0.01 per GB in each direction** when traffic crosses Availability Zones (AZs). When your Tier 1 DaemonSets send 2 million spans/sec to Tier 2 Routers in different AZs, you generate massive network bills.

* **100K QPS:** ~1 TB/hour of telemetry. Crossing AZs costs $0.02/GB total (out + in). This equals ~$14,000/month just in network fees.
* **200K QPS:** ~$28,000/month in inter-AZ fees.
* **Mitigation:** You must configure Kubernetes **Topology Aware Routing** (`topologyKeys`) on the Tier 2 headless service so DaemonSets only forward spans to Routers within their *same* AZ.

### B. Amazon Managed Service for Prometheus (AMP)

AMP charges are heavily driven by ingestion volume. The tiered pricing is $0.90 per 10 million samples for the first 2 billion, and drops to $0.35 per 10 million for the next 250 billion.

* A production cluster running 150 nodes and scraping high-resolution metrics (15-second intervals) generates roughly 53.6 billion samples per month, costing **~$4,433/month** for ingestion alone.
* If your infrastructure scales to support 200K QPS, you will likely run hundreds of nodes and thousands of pods. Expect AMP costs to scale into the **$10,000 to $25,000/month** range based purely on custom application metric cardinality (e.g., tracking 200K QPS broken down by HTTP route and status code).

### C. Amazon S3 Storage & API Costs

Tempo and Loki compress data into Parquet/Chunk files before sending to S3, bypassing EBS gp3 fees.

* **Storage:** S3 Standard is $0.023/GB. At 100K QPS (assuming a 5% tail-sampling retention rate), you will store roughly 2 to 3 TB of data per day. A 14-day retention window requires ~42 TB of S3 storage, costing **~$960/month**.
* **API Costs (PUT Requests):** S3 charges $0.005 per 1,000 PUT requests. If your Ingesters flush too frequently (e.g., small 1MB files instead of batching 50MB files), you can generate millions of PUT requests daily. Proper batching tuning in the Helm `values.yaml` is required to keep API costs under a few hundred dollars a month.


### 1. Grafana Mimir vs. Amazon Managed Prometheus (AMP)

At hyper-scale, **Self-Hosted Grafana Mimir is drastically more cost-effective than AMP, but requires rigorous operational tuning.** AMP is fundamentally a luxury of zero-maintenance.

#### Why Your Mimir Pods Were Crashing

The instability you experienced is a well-documented architectural quirk of how Mimir interacts with Go's memory management in Kubernetes. The crashes and pod churn are rarely due to Mimir's inability to scale, but rather misconfigurations in resource limits:

* **The `store-gateway` CPU Death Spiral:** Mimir `store-gateway` pods are designed to be extremely memory-heavy to cache index entries and postings lists. If you set the Kubernetes memory limits too low (e.g., 512Mi), Go's runtime sets the `GOMEMLIMIT` to match. The pod will suddenly spike to using 2+ full CPU cores doing absolutely nothing. This happens because the Go Garbage Collector (`runtime.gcBgMarkWorker`) consumes 95% of the CPU desperately trying to keep heap memory under the artificial limit. **Fix:** Drastically increase the memory requests for `store-gateway` and `ingester` pods (e.g., to 2Gi or higher) to stop the garbage collection thrashing.
* **Ingester OOMKills:** The `ingester` buffers active metric series in memory before flushing blocks to S3. If they run out of memory, they OOMKill. You must size your Ingester nodes for RAM (e.g., using AWS `r6i` instances) rather than CPU.

#### The Cost Math: AMP vs. Mimir

AMP charges on a tiered ingestion model starting at $0.90 per 10 million samples for the first 2 billion, dropping to $0.35, and eventually $0.16.

* If your infrastructure generates **50 billion samples a month**, AMP ingestion will cost roughly **$4,433 per month**.
* If you self-host Mimir, those same 50 billion samples cost exactly the price of the underlying S3 bucket and EC2 nodes. A self-managed Mimir cluster handling 50k samples/sec costs roughly **$2,500/month** (including labor estimates), whereas managed Prometheus services can hit **$4,000/month** or more for the same volume.
* **A major AMP cost-saver:** If you stick with AMP, you must enable **Prometheus Native Histograms**. AMP supports native histograms, which count each populated bucket as only 0.25 of a sample instead of 1. For high-cardinality latency metrics, this cuts AMP ingestion costs by 60–80%.

---

### 2. Total Monthly AWS Observability Cost Model (EKS, EC2, Network, S3)

To calculate the *total* observability bill, we must factor in the EC2 nodes (assuming `r6i.2xlarge` memory-optimized instances at ~$368/month on-demand), S3 storage API charges, and the massive AWS network transfer fees.

*Assumptions: 14-day retention for Traces/Logs, 30-day for Metrics. Includes the OTel Router + Processor architecture.*

| App QPS | EC2 Nodes (OTel + Loki + Tempo) | Storage (S3 Standard) | Inter-AZ Network Tax (Without TAR) | Total Bill using Self-Hosted Mimir | Total Bill using AWS AMP |
| --- | --- | --- | --- | --- | --- |
| **20K** | ~12 Nodes ($4,400) | $350 | ~$2,800 | **~$8,500 / month** | **~$10,500 / month** |
| **50K** | ~24 Nodes ($8,800) | $850 | ~$7,000 | **~$18,650 / month** | **~$24,150 / month** |
| **100K** | ~48 Nodes ($17,600) | $1,600 | ~$14,000 | **~$36,200 / month** | **~$49,200 / month** |
| **200K** | ~90 Nodes ($33,100) | $3,200 | ~$28,000 | **~$68,300 / month** | **~$85,000+ / month** |

---

### 3. Critical Cost Optimizations for 250K QPS

If you deploy this architecture blindly, your AWS bill will bankrupt the project. You must implement these two architectural fixes:

#### A. Taming the Inter-AZ Network Tax

Notice the massive "Inter-AZ Network Tax" in the table above. AWS charges $0.01 per GB in each direction when data crosses Availability Zones, meaning a pod in AZ-A talking to a pod in AZ-B effectively costs **$0.02 per GB round trip**.
When thousands of your Tier 1 DaemonSets blast telemetry round-robin to Tier 2 Routers in different zones, you bleed capital.

**The Fix:** You must implement Kubernetes **Topology Aware Routing (TAR)**.
Add `spec.trafficDistribution: PreferSameZone` to your OTel Router Kubernetes Services, and ensure the backing Deployments use `topologySpreadConstraints` keyed to `topology.kubernetes.io/zone`. This forces DaemonSets to forward telemetry only to Routers in their physical datacenter zone, dropping the network bill by up to **90%**.

#### B. EC2 Spot & Compute Savings Plans

The EC2 node costs calculated above use On-Demand pricing. Because OTel Routers and Loki/Tempo Queriers are stateless, they should run entirely on **AWS Spot Instances** (which offer up to a 67% discount on `r6i.2xlarge` instances). Ingesters and Processors (which hold memory state) must remain on On-Demand or Reserved Instances.

To eliminate the extreme inter-AZ network costs, the Topology Aware Routing (TAR) configurations must be applied specifically to the **Tier 2 (Router)** layer.

The Tier 1 DaemonSets are already running on every node, so they inherently exist in every zone. The goal is to force those DaemonSets to only send telemetry to Tier 2 Routers located in their physical datacenter zone, preventing the traffic from crossing AWS Availability Zone boundaries.

### 1. Tier 2 Router Implementation (Helm Configuration)

These changes are applied to your Tier 2 Router Helm chart (`values.yaml`). You must configure both the Kubernetes `Service` (to restrict the traffic flow) and the `Deployment` (to guarantee Routers exist in every zone to receive that traffic).

```yaml
# ---------------------------------------------------------
# Tier 2: OTel Collector Router (Deployment)
# ---------------------------------------------------------
mode: deployment

# 1. The Service Configuration
service:
  # Introduces Topology Aware Routing for Kubernetes 1.30+
  trafficDistribution: PreferSameZone
  
  # Fallback for Kubernetes 1.29 and older
  annotations:
    service.kubernetes.io/topology-mode: "auto"

# 2. The Deployment Configuration
# You MUST spread the Routers evenly across all AZs. If an AZ lacks a Router, 
# the DaemonSets in that AZ will be forced to send traffic cross-zone, defeating the purpose.
affinity:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: opentelemetry-collector-router

```

*Note: You do not apply this to the Tier 3 Processors. The Tier 2 Routers must calculate the consistent hash and send the spans to the correct Tier 3 Processor regardless of which AZ that Processor lives in. The 90% network savings comes entirely from optimizing the massive "blind" firehose of spans between Tier 1 and Tier 2.*

### 2. Spot Instance Configuration for Stateless Components

To realize the compute savings, you must run the stateless components of this architecture on AWS Spot Instances, which offer up to a 67% discount over On-Demand.

* **100% Spot Eligibility:** Tier 2 Routers, Loki Queriers, Tempo Queriers, and Distributors. (These hold no state and can be terminated at any time without data loss).
* **100% On-Demand / Reserved:** Tier 3 Processors, Loki Ingesters, and Tempo Ingesters. (These hold telemetry in memory before flushing to S3; Spot terminations here will cause data loss).

### 3. The Optimized Monthly Cost Table

By eliminating ~90% of the cross-AZ network traffic and migrating roughly half of the EC2 compute footprint to Spot Instances, the financial viability of the platform changes drastically.

| App QPS | Optimized EC2 Nodes (50% Spot) | Storage (S3 Standard) | Inter-AZ Network Tax (With TAR) | Total Bill using Self-Hosted Mimir | Total Bill using AWS AMP |
| --- | --- | --- | --- | --- | --- |
| **20K** | ~$3,080 | $350 | ~$280 | **~$4,660 / month** | **~$6,660 / month** |
| **50K** | ~$6,160 | $850 | ~$700 | **~$9,710 / month** | **~$15,210 / month** |
| **100K** | ~$12,320 | $1,600 | ~$1,400 | **~$18,320 / month** | **~$31,320 / month** |
| **200K** | ~$23,170 | $3,200 | ~$2,800 | **~$33,170 / month** | **~$49,870 / month** |

At 200,000 QPS, implementing Topology Aware Routing and separating stateless components onto Spot instances reduces your overall infrastructure bill by over **$35,000 a month**, making the Self-Hosted Mimir/Loki/Tempo stack highly competitive against fully managed SaaS offerings.



| Traffic Volume | Grafana Cloud | Dash0 | IBM Instana | Dynatrace | Datadog | Self-Hosted (Optimized) | Strategic Recommendation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **2,000 QPS** | ~$1,400 | ~$2,000 | ~$1,500 | ~$2,700 | ~$6,200 | ~$1,000 | **Grafana Cloud or Dash0:** The minimal infrastructure savings of self-hosting are immediately wiped out by the labor costs of maintaining databases. |
| **10,000 QPS** | ~$6,500 | ~$9,300 | ~$4,500 | ~$9,000 | ~$29,000 | ~$3,500 | **IBM Instana or Grafana Cloud:** Instana is highly cost-effective if running large, dense on-premise servers; Grafana wins for highly distributed Kubernetes clusters. |
| **50,000 QPS** | ~$30,000 | ~$46,800 | ~$22,500 | ~$45,000 | ~$146,000 | ~$18,650 | **Self-Hosted or Hybrid:** Commercial SaaS requires aggressive volume discount negotiation at this tier. Unit economics dictate building an internal platform team. |
| **100,000+ QPS** | $60,000+ | $90,000+ | $45,000+ | $85,000+ | $250,000+ | ~$36,200 | **Strictly Self-Hosted:** Commercial SaaS unit economics fail entirely. Deploy the 3-Tier OpenTelemetry architecture with Topology Aware Routing on AWS. |