# Observability Runtime

This directory contains the platform-team-owned active Kubernetes runtime manifests for the OpenTelemetry observability platform on Amazon EKS.

---

## Directory Structure & Organization

```text
observability-runtime/
├── gateways/                         # Modular Two-Tier Central Gateway Fleet
│   ├── 00-gateway-rbac.yaml          # ClusterRole & ServiceAccount bindings for EndpointSlice discovery
│   ├── 01-gateway-tier2-router.yaml  # Tier 2 Stateless Router (Deployment with consistent hashing)
│   └── 02-gateway-tier3-processor.yaml # Tier 3 Stateful Processor (Spanmetrics + Tail Sampling + Exporters)
├── grafana-ingress.yaml              # Internet-facing ALB Ingress for Grafana
├── grafana-dashboards-configmap.yaml # Baseline Golden Signal & Meta-Monitoring Grafana Dashboards
├── mimir-ruler-rules-configmap.yaml  # Google SRE multi-window SLO burn-rate alerts (mounted to Mimir Ruler)
├── alert-sink.yaml                   # Webhook receiver for slow-burn ticket-severity alerts
└── optional-extensions/              # Optional Enterprise Extensions
    ├── svc-nlb-otel-gateway.yaml     # Internal Ingestion NLB (Instance target type, cross-VPC peered)
    ├── kafka-stub.yaml               # In-cluster Kafka buffer stub
    ├── opensearch-index-bootstrap-job.yaml # OpenSearch index template + 7-day ISM policy
    └── README.md                     # Instructions for enabling the Kafka -> Logstash -> OpenSearch path
```

---

## Core Architecture Patterns

1. **Two-Tier Gateway Topology:**
   - **Tier 2 (Stateless Router - Deployment):** Ingress layer that hashes by `traceID` (and `service.name`) using the OTel `loadbalancing` exporter across Kubernetes EndpointSlices.
   - **Tier 3 (Stateful Processor - StatefulSet):** Receives trace-affinity routed spans, enforces `memory_limiter`, computes RED metrics via pre-sampling `spanmetrics`, and evaluates `tail_sampling` before exporting to backends.
2. **Loki-First Native OTLP Logging:**
   - Applications emit logs over native OTLP (`otlphttp/loki`) into S3-backed Loki for lightweight, cost-effective storage and instant trace-to-log correlation.
3. **Optional Kafka / OpenSearch Pipeline:**
   - For high-burst protection (>25k events/sec) or full-text SIEM analytics, logs can be buffered via Kafka and Logstash into OpenSearch (toggled via `-var="deploy_opensearch_stack=true"`).
4. **Google SRE SLO Burn-Rate Alerting & Incident Escalation:**
   - Mimir Ruler evaluates 14.4x/6x/3x/1x burn rates against application RED metrics, routing critical pages to AWS Systems Manager Incident Manager (multi-region escalation) and slow burns to Alert-Sink.
5. **Meta-Monitoring:**
   - Self-monitoring collectors scrape `:8888`/`:8889` into Mimir with data-loss alerts and a decoupled AWS CloudWatch NLB watchdog.

---

## Ownership Model

- **Platform Teams Own:** Central collector gateway baselines, routing policies, sampling defaults, backend integrations, and operational alerts.
- **For Observability Product & Onboarding Contracts:** See [`../observability-as-a-product/`](../observability-as-a-product/).
