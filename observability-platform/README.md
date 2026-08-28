# Observability Platform

This directory contains the platform-team-owned surface for the multi-cluster OpenTelemetry platform on Amazon EKS.

---

## Directory Structure & Organization

```text
observability-platform/
├── k8s-manifests/                     # Active Kubernetes manifests (applied by make k8s-deploy-otel)
│   ├── otel-collector-gateway.yaml    # Two-Tier Gateway (Stateless Router + Stateful Processor with Tail Sampling)
│   ├── svc-nlb-otel-gateway.yaml      # Internal Ingestion NLB (Instance target type, cross-VPC peered)
│   ├── grafana-ingress.yaml           # Internet-facing ALB Ingress for Grafana
│   ├── grafana-dashboards-configmap.yaml # Baseline Golden Signal & Meta-Monitoring Grafana Dashboards
│   ├── mimir-ruler-rules-configmap.yaml  # Google SRE multi-window SLO burn-rate alerts (mounted to Mimir Ruler)
│   ├── goalert.yaml                   # Self-hosted GoAlert on-call pager & escalation policy
│   ├── alert-sink.yaml                # Webhook receiver for slow-burn ticket-severity alerts
│   └── optional-extensions/           # Optional Enterprise Extensions (Kafka buffer & OpenSearch ISM bootstrap)
│       ├── kafka-stub.yaml            # In-cluster Kafka buffer stub
│       ├── opensearch-index-bootstrap-job.yaml # OpenSearch index template + 7-day ISM policy
│       └── README.md                  # Instructions for enabling the Kafka -> Logstash -> OpenSearch path
├── onboarding/                        # Paved Road: Service contract, 4 levels of instrumentation & SDK templates
├── gateway-policies/                  # Platform Policies: Multitenant routing & sampling budgets
├── dashboards-and-alerts/             # Visuals & SRE: Raw dashboard JSONs, Helm charts, and META_MONITORING.md
└── gitops/                            # GitOps: Argo CD app-of-apps & regional gateway baseline aliases
```

---

## Core Architecture Patterns

1. **Two-Tier Gateway Topology:**
   - **Tier 1 (Router - Deployment):** Ingress layer that hashes by `traceID` using the OTel `loadbalancing` exporter.
   - **Tier 2 (Processor - StatefulSet):** Receives trace-affinity routed spans, enforces `memory_limiter`, filters health check noise, and evaluates `tail_sampling` before exporting to backends.
2. **Loki-First Native OTLP Logging:**
   - Applications emit logs over native OTLP (`otlphttp/loki`) into S3-backed Loki for lightweight, cost-effective storage and instant trace-to-log correlation.
3. **Optional Kafka / OpenSearch Pipeline:**
   - For high-burst protection (>25k events/sec) or full-text SIEM analytics, logs can be buffered via Kafka and Logstash into OpenSearch (toggled via `-var="deploy_opensearch_stack=true"`).
4. **Google SRE SLO Burn-Rate Alerting & GoAlert:**
   - Mimir Ruler evaluates 14.4x/6x/3x/1x burn rates against application RED metrics, routing critical pages to GoAlert and slow burns to Alert-Sink.
5. **Meta-Monitoring:**
   - Self-monitoring collectors scrape `:8888`/`:8889` into Mimir with data-loss alerts and a decoupled AWS CloudWatch NLB watchdog.

---

## Ownership Model

- **App Teams Own:** Instrumentation quality, service metadata (`service.name`, `team`, `deployment.environment`), SLO targets, and alerting thresholds.
- **Platform Teams Own:** Collector baselines, gateway routing policy, tail sampling defaults, backend integrations, and GitOps paved roads.
- **FinOps & Security Teams Rely On:** Centralized controls for S3 retention, compression, rate-limiting, and tenant isolation.
