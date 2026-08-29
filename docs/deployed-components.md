# Deployed Components & Helm Release Inventory

This document provides the full, version-pinned inventory of all deployed workloads, platform controllers, and observability backends across the EKS cluster(s).

---

## 1. Observability Cluster Components

### Active Components (Default Stack)

| Component | Helm Chart / Image | Pinned Version | Topology & Sizing | Purpose |
|---|---|---|---|---|
| **Amazon Managed Prometheus (AMP)** | AWS Native Workspace | `aws_prometheus_workspace` | Serverless, AWS SigV4 Auth, EKS Pod Identity | Primary Prometheus metrics store with zero pod maintenance |
| **Grafana Loki** | `grafana/loki` | `7.2.0` | SingleBinary, 1 pod, gp3 cache, S3 chunk storage | Primary log engine, native OTLP ingest (`/otlp`) |
| **Grafana Tempo** | `grafana/tempo` | `1.24.4` | Monolithic, 1 pod, S3 block storage | Distributed tracing backend, OTLP gRPC ingest (`:4317`) |
| **Grafana** | `grafana/grafana` | `10.5.15` | 1 pod, sidecar dashboard provisioner | Unified UI with AMP (SigV4), Loki, and Tempo datasources |
| **Central OTel Gateway** | `otel/opentelemetry-collector-contrib` | `0.156.0` | 2-Tier Fleet: 2× Router Deployments + 3× Processor StatefulSets | Ingress routing, OTTL normalization, tail sampling |
| **GoAlert** | `goalert/goalert` | `v0.34.1` (digest-pinned) | 1 pod + PostgreSQL StatefulSet | On-call pager escalation for fast-burn critical alerts |
| **Alert Sink** | `mendhak/http-https-echo` | `31` | 1 pod | Webhook echo receiver for warning/ticket-severity alerts |
| **OpenTelemetry Operator** | `opentelemetry-operator` | `0.120.0` | 1 pod | Injects runtime auto-instrumentation and manages Collector CRDs |
| **cert-manager** | `jetstack/cert-manager` | `v1.21.1` | 3 pods (controller, webhook, cainjector) | Generates internal TLS certificates for OTel Operator webhooks |
| **AWS Load Balancer Controller** | `eks/aws-load-balancer-controller` | `3.4.3` | 1 pod | Provisions AWS ALBs (Grafana, demo app) and NLBs (Gateway) |
| **Karpenter** | `oci://public.ecr.aws/karpenter` | `1.0.6` | NodePool + EC2NodeClass | Automatic spot EC2 provisioning for traffic bursts |
| **Cluster Storage gp3** | Local chart `cluster-storage/` | — | StorageClass (`gp3`, encrypted, volumeBindingMode: Immediate) | Default storage baseline provisioned before any PVC |

### Alternative & Optional Components (Disabled by Default)

| Component | Helm Chart / Image | Pinned Version | Default State | Activation Flag & Rationale |
|---|---|---|---|---|
| **Mimir** | `grafana/mimir-distributed` | `6.1.0` | **Disabled** (Replaced by AMP) | Set `use_amazon_managed_prometheus = false` to run fully open-source Prometheus on S3 (adds 10 stateful pods). |
| **Kafka Buffer** | `bitnami/kafka` | `3.6` | **Disabled** (Optional Enterprise Buffer) | Uncomment in `helm-charts.tf` and gateway manifests for burst absorption (>25k events/sec) or multi-consumer SIEM fan-out. |
| **OpenSearch** | `opensearch-project/opensearch` | `3.8.0` | **Disabled** (Optional Log Analytics) | Enable for SIEM security analytics, free-text regex search, and Lucene queries. |
| **OpenSearch Dashboards** | `opensearch-project/opensearch-dashboards` | `3.8.0` | **Disabled** (Optional Analytics UI) | Web console for OpenSearch index discovery and log visualization. |
| **Logstash** | `elastic/logstash` | `8.5.1` | **Disabled** (Optional Ingest Pipeline) | Consumes JSON logs from Kafka topic `otel-logs-buffer` and indexes into OpenSearch. |

---

## 2. Workload Cluster Components

| Component | Image / Package | Pinned Version | Deployment Shape | Purpose |
|---|---|---|---|---|
| **Node OTel Collector Agent** | `otel/opentelemetry-collector-contrib` | `0.156.0` | DaemonSet (`hostNetwork: true`) | Collects container logs (`filelog`), kubelet metrics, and enriches `k8sattributes` via Downward API `status.hostIP:4317`. |
| **OBI eBPF DaemonSet** | `otel/ebpf-instrument` | `v0.12.2` | DaemonSet (`hostPID: true`, `hostNetwork: true`) | Kernel-space non-invasive HTTP RED metrics and TCP drop visibility, streaming over loopback to node agent. |
| **OTel Operator** | `opentelemetry-operator` | `0.120.0` | 1 pod | Injects Python runtime auto-instrumentation via pod annotations. |
| **cert-manager** | `jetstack/cert-manager` | `v1.21.1` | 3 pods | Webhook TLS for OTel Operator admission controller. |
| **AWS Load Balancer Controller** | `eks/aws-load-balancer-controller` | `3.4.3` | 1 pod | Manages the internet-facing Application Load Balancer for the demo app. |
| **Go Product Service** | `okkarthik/golang-product-service` | `latest` (Docker Hub) | 2 replicas, Deployment + ClusterIP | Programmatically instrumented via OpenTelemetry Go SDK (`telemetry.go`), emits W3C trace context. |
| **Python Product Info Service** | `okkarthik/python-product-info-service` | `latest` (Docker Hub) | 2 replicas, Deployment + ClusterIP | Auto-instrumented by OTel Operator (`instrumentation.opentelemetry.io/inject-python`). |

---

## 3. AWS Infrastructure Baseline

| Resource | Terraform Construct | Sizing / Configuration | FinOps / Networking Impact |
|---|---|---|---|
| **EKS Clusters** | `module.eks` (terraform-aws-modules/eks) | Kubernetes `1.31` | Single cluster (`observability-cluster`) in dev, dual peered clusters in multi-cluster mode. |
| **Managed Node Groups** | `eks_managed_node_groups` | 2× `t3.large` spot (min 2, max 6) | Cost-effective spot instances with Karpenter burst scaling. |
| **S3 Telemetry Storage** | `aws_s3_bucket` | 2 buckets (Loki logs, Tempo traces) | Lifecycle expiration at 7 days, server-side encryption with S3 managed keys (`AES256`). |
| **S3 Gateway VPC Endpoints** | `aws_vpc_endpoint` (type `Gateway`) | `com.amazonaws.us-east-1.s3` | **$0.00/GB data transfer**, routes all log/trace uploads directly over internal AWS network, completely bypassing NAT Gateways. |
| **AMP Workspace** | `aws_prometheus_workspace.amp` | Serverless metric workspace | Ingestion via SigV4, eliminates 10 stateful Mimir pods (~1.9 GiB memory saved). |
| **Networking & Routing** | `aws_vpc`, `aws_nat_gateway` | 1 NAT Gateway per VPC | Dual VPCs (`10.0.0.0/16` and `10.1.0.0/16`) with bidirectional VPC Peering routes. |
