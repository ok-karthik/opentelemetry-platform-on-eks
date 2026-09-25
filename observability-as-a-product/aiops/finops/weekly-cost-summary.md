# Weekly FinOps Observability Cost & Telemetry Attribution Report

- **Generated At:** `2026-09-25 10:06:30 UTC`
- **Mode:** `Simulated Sandbox Telemetry`
- **Routing Tag:** `tenant.id` (Central Observability Gateway policy)

## Executive Summary

Total cluster ingestion rate is currently **4,815.2 spans/s**, **5,696.3 logs/s**, and **1,207.1 metric pts/s**.
Total estimated S3 observability storage footprint across Loki, Tempo, and Mimir is **244.2 GB**.

### Tenant Breakdown

| Tenant ID | Spans (rate/s) | Logs (rate/s) | Metrics (rate/s) | S3 Storage (GB) | WoW Growth | Anomaly Status |
|---|---|---|---|---|---|---|
| `payments` | 3,200.0 | 4,500.8 | 840.1 | 182.4 GB | `+215.4%` | 🚨 **ANOMALOUS** |
| `platform-aiops` | 45.0 | 95.0 | 12.0 | 4.2 GB | `+12.0%` | ✅ Healthy |
| `product` | 1,450.2 | 890.5 | 320.0 | 48.5 GB | `+8.2%` | ✅ Healthy |
| `unallocated` | 120.0 | 210.0 | 35.0 | 9.1 GB | `-4.5%` | ✅ Healthy |

## Root-Cause Correlation & FinOps Alerts

### Tenant Alert: `payments` (+215.4% Growth)
> **Root Cause Analysis:** CRITICAL ANOMALY: Log volume tripled (+215.4% WoW). Correlation: 'checkout-service' commit #7f8a12 enabled DEBUG-level OTLP logger without rate limiter.
> 
> **Recommended Remediation:**
> 1. Apply gateway drop policy in `observability-as-a-product/gateway-policies/` to filter DEBUG logs at Tier 2.
> 2. Engage team lead via Slack channel to revert log level or enable client-side sampling.
> 3. Estimated Monthly Savings: **~$185/month** in avoided S3 write and query operations.

## Methodology & Metrics Queried
- Spans Ingest: `sum by (tenant_id) (rate(otelcol_receiver_accepted_spans_total[1h]))`
- Logs Ingest: `sum by (tenant_id) (rate(otelcol_receiver_accepted_log_records_total[1h]))`
- Metrics Ingest: `sum by (tenant_id) (rate(otelcol_receiver_accepted_metric_points_total[1h]))`
- Storage Attribution: Derived from Loki & Tempo chunk prefix sizing and S3 Gateway VPC endpoint telemetry.
