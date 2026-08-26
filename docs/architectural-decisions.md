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

### 3. Dedicated Observability Cluster in Peered VPC

**Chosen:** A dedicated observability cluster in its own VPC, peered to the workload VPC. Telemetry crosses the peering link over an *internal* NLB; nothing about the path touches the public internet.

**Rejected — One cluster with a `monitoring` namespace:** Cheaper and simpler, but the failure mode is that the system you use to debug an incident is running on the cluster experiencing the incident. A node-pressure event or a bad workload rollout takes the telemetry with it, and Mimir's compaction spikes compete with application pods for the same nodes.

**What it cost:** A second EKS control plane (~$73/month), a second NAT gateway, VPC peering routes in both directions, and a real constraint on the NLB: `nlb-target-type: instance` is set rather than `ip`, because peered-VPC traffic to pod IPs takes an asymmetric return path.

**What it bought:** A genuine blast-radius boundary, independent scaling (the observability cluster runs Karpenter, the workload cluster does not need it), and the ability to demonstrate the multi-cluster fan-in that a regional platform actually looks like.

---

### 4. Self-Hosted LGTM on S3 (Chart Traps & Operational Surface)

**Chosen:** Loki, Tempo, Mimir, and Grafana from their individual upstream charts, all backed by S3, all reached through EKS Pod Identity rather than static credentials.

**Rejected — Amazon Managed Prometheus (AMP) + Managed Grafana (AMG):** Less to operate, but AMP is metrics only: traces and logs still need X-Ray and CloudWatch, so you get three query languages and no single correlated view.  
**Rejected — Datadog or an equivalent SaaS:** Per-host and per-GB pricing makes the observability bill a function of traffic, and it puts the exit cost of the platform outside your control.  
**Rejected — The all-in-one `lgtm` chart:** Convenient, but it hides which component owns which setting, and it cannot be tuned per component.

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
