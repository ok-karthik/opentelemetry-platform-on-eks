# AIOps Phase 3: FinOps Tenant Cost Correlation

This module implements **[Phase 3 of the AIOps & Portability Plan](../../../docs/aiops-portability-plan-archive.md)**: an automated FinOps and tenant cost-correlation agent that leverages the platform's multi-tenant telemetry pipeline (`tenant.id`).

## Platform Mechanism

The central OpenTelemetry Gateway (`observability-as-a-product/gateway-policies/otel-gateway-multitenant.yaml`) normalizes and tags all traces, metrics, and logs with `resource.attributes["tenant.id"]`.

This enables high-fidelity attribution of observability storage and network spend down to individual product teams:
- **Metrics & Spans Ingestion:** Tracked via collector metrics (`otelcol_receiver_accepted_*` grouped by `tenant.id`).
- **S3 Storage Footprint:** Evaluated via chunk prefix volume in Loki, Tempo, and Mimir S3 buckets.
- **Anomaly Detection:** Flags week-over-week (WoW) volume increases exceeding normal variance thresholds.
- **Root-Cause Correlation:** Correlates log/trace volume spikes with recent git commits or application logger configuration changes.

## Running the Cost Analyzer

```bash
# Generate report against local port-forward or in-cluster Mimir
python3 observability-as-a-product/aiops/finops/cost-analyzer.py --prometheus-url http://localhost:9090/prometheus

# Deliverable generated at:
# observability-as-a-product/aiops/finops/weekly-cost-summary.md
```

## Deliverable Sample

See [`weekly-cost-summary.md`](weekly-cost-summary.md) for an example report generated on demand.
