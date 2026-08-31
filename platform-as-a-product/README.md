# Platform as a Product (Paved Roads & Governance)

This directory contains the product surface of the internal observability platform. It defines the paved roads, onboarding contracts, gateway policy templates, self-service SLO rule generators, and GitOps baselines.

---

## Directory Structure

```text
platform-as-a-product/
├── onboarding/                     # Paved Road: Service onboarding contract & 4 levels of telemetry
│   ├── service-onboarding-contract.md # Service metadata, SLO definitions & ownership contract
│   ├── instrumentation-tiers-and-ebpf.md # Level 1 (eBPF) to Level 4 (SaaS) architecture
│   └── instrumentation-manifests/  # Multi-runtime OTel CRs (Python/Java/Node) & Go SDK template
│
├── gateway-policies/               # Platform Policy Templates
│   ├── otel-gateway-multitenant.yaml # Tenant-aware routing connector
│   └── otel-gateway-tail-sampling.yaml # Tail sampling cost budgeting & latency retention rules
│
├── dashboards-and-alerts/          # Visuals & SRE Engineering
│   ├── golden-signals/             # Baseline Grafana dashboard JSONs (Go, Python, Meta-monitoring)
│   ├── helm-chart/                 # GitOps PrometheusRule & GrafanaDashboard Helm generator
│   └── META_MONITORING.md          # Meta-monitoring architecture & dead-man's snitch design
│
└── argocd/                         # GitOps Architecture
    ├── root-application.yaml       # Argo CD App-of-Apps root definition
    ├── appproject-platform.yaml    # Platform AppProject with RBAC & cluster constraints
    └── apps/                       # Child Application manifests
```

---

## The 4 Pillars of Platform Governance

1. **Service Onboarding Contract (`onboarding/`):**
   - App teams agree on standard resource attributes (`service.name`, `service.namespace`, `deployment.environment`, `team`, `tenant.id`) and define explicit SLO availability targets.
2. **The 4 Tiers of Telemetry (`onboarding/instrumentation-tiers-and-ebpf.md`):**
   - Combines Level 1 Kernel-Space eBPF (instant OOM & TCP retransmits) with Level 2 Operator auto-instrumentation, Level 3 Go SDK bootstrap, and Level 4 Vendor SaaS protection.
3. **FinOps & Policy Controls (`gateway-policies/`):**
   - Central tail sampling retains 100% of errors and latency outliers (>2s) while downsampling high-volume healthy 200 OK spans to reduce storage costs by up to 80%.
4. **Self-Service GitOps (`dashboards-and-alerts/helm-chart/` & `argocd/`):**
   - App teams onboard via small Helm `values.yaml` files, and Argo CD automatically renders `PrometheusRule` multi-window SLO burn-rate alerts and Grafana dashboards.
