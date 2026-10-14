# AWS-Native Observability (CloudWatch) vs. Self-Hosted LGTM + OpenTelemetry

Pricing and feature comparison, from 2K to 200K QPS, for several application setups.

- **Prices:** us-east-1 list prices, pulled October 2026 from the AWS Price List API (`AmazonCloudWatch`, `AmazonPrometheus`, `AmazonGrafana`; the same data the AWS Pricing Calculator uses), the [CloudWatch pricing page](https://aws.amazon.com/cloudwatch/pricing/), and the [AWS DevOps Agent pricing page](https://aws.amazon.com/devops-agent/pricing/).
- **Model:** [`aws-native-vs-lgtm-cost-model.py`](aws-native-vs-lgtm-cost-model.py). Every cost number below comes from it. Change an assumption, re-run it.
- **LGTM side:** the repo's own figures from `README.md` and `cost-calculation-draft.md`, plus a Grafana HA add-on (section 9).

## Contents

1. [Short answer](#1-short-answer)
2. [Method and assumptions](#2-method-and-assumptions)
3. [Rate card used](#3-rate-card-used)
4. [Results: monthly cost](#4-results-monthly-cost)
5. [Feature comparison](#5-feature-comparison)
6. [AWS-native bill of materials: which services you actually need](#6-aws-native-bill-of-materials-which-services-you-actually-need)
7. [AI and AIOps: AWS services vs. what you can do on LGTM](#7-ai-and-aiops-aws-services-vs-what-you-can-do-on-lgtm)
8. [Log search](#8-log-search)
9. [Making Grafana stable](#9-making-grafana-stable)
10. [The hybrid approach in detail](#10-the-hybrid-approach-in-detail)
11. [Recommendations by application setup](#11-recommendations-by-application-setup)
12. [Other considerations](#12-other-considerations)
13. [What would change these conclusions](#13-what-would-change-these-conclusions)
14. [Limits of this analysis](#14-limits-of-this-analysis)

---

## 1. Short answer

1. **Neither is "better". They trade money for people-time.** CloudWatch costs more per GB and needs almost no operations. LGTM costs less per GB and needs a platform team.
2. **Below roughly 8K QPS, AWS-native is cheaper once you count labour.** Above that, LGTM wins on infrastructure by about 2–3.5x. All-in, it depends on how disciplined your CloudWatch setup is (section 4.2).
3. **The README's old "88–93% saved" claim compared against an untuned, ingest-everything bill.** Against a tuned CloudWatch setup the infrastructure saving is about 70%, and against a best-case setup with labour included, LGTM is *more* expensive between 20K and 100K QPS. The README has been corrected.
4. **AWS has real capabilities LGTM does not match out of the box:** log anomaly detection, managed sensitive-data masking, Live Tail, Logs Insights, vended-log ingestion with zero plumbing, Application Signals SLOs, and AI investigations that already understand your AWS resources (sections 5 and 7).
5. **You do not have to choose.** AWS DevOps Agent connects to a self-hosted Grafana through MCP, and Grafana's MCP server exposes Loki and Tempo query tools (section 7). And this repo is already a partial hybrid (section 10).
6. **One real defect in this repo:** Grafana runs as a single replica with persistence disabled (`grafana.yaml.tftpl`: `replicas: 1`, `persistence.enabled: false`). Cheap to fix (section 9).
7. **A second defect, in the README:** its telemetry volume table was about 1,000x too low for spans and about 25x too low for logs against its own stated rule. It is corrected in the README.

---

## 2. Method and assumptions

### Traffic model (same as the repo)

1 app QPS = 8 spans/s + 2 log lines/s. A month is 730 h = 2,628,000 s.

| Item | Assumption | Source |
|---|---|---|
| Span size | 1 KB (512 B in the best case) | AWS's own pricing example uses 1 KB per span |
| Log line | 512 B | my assumption |
| Metric sample | 400 B on the wire | AWS: "10–15 attributes is 300–600 bytes" |
| Scrape interval | 30 s (86,400 samples/series/month) | my assumption |
| Active series | 19K / 280K / 625K / 955K / 1.6M | back-solved from the repo's AMP line, so the two models agree |
| Retention | 14 d traces/logs, 30 d metrics | repo |
| Infra vs app metrics | 60% / 40% | my assumption (decides how much qualifies for the cheap Container Insights rate) |

Raw volume per month, before any sampling or filtering:

| QPS | Spans | Log lines | Log volume at 512 B |
|---|---|---|---|
| 2K | 42 B | 10.5 B | 5.0 TB |
| 20K | 420 B | 105 B | 50 TB |
| 50K | 1.05 T | 263 B | 125 TB |
| 100K | 2.1 T | 526 B | 250 TB |
| 200K | 4.2 T | 1.05 T | 500 TB |

### The three AWS-native configurations

| Name | What it means | Realistic? |
|---|---|---|
| **A1 Out-of-the-box** | 100% of spans ingested (Transaction Search), all logs in Standard class, all metrics as OTel metrics. No filtering. | This is what you get if nobody tunes anything. Strawman ceiling. |
| **A2 Tuned** | 5% of spans, half of log volume dropped before ingest and the rest in the $0.25/GB class, half the metric series. Collector fleet at 40% of the repo's compute. | A competent team after one cost-review quarter. **Use this one for fair comparison.** |
| **A3 Best case** | 2% of spans at 512 B, 25% of log volume in the $0.25 class, 35% of series. | Disciplined, with a FinOps owner. |

A2 and A3 need collector-side sampling and filtering, which means running a gateway fleet. **AWS-native is not zero-infrastructure once you tune it.** I charged 40% of the repo's compute for it.

### Labour (the assumption that moves the answer most)

| QPS | 2K | 20K | 50K | 100K | 200K |
|---|---|---|---|---|---|
| FTE for LGTM | 0.25 | 0.5 | 1.0 | 1.5 | 2.0 |
| FTE for AWS-native | 0.05 | 0.1 | 0.2 | 0.3 | 0.5 |

Priced at $15,000 per FTE-month (a $180K loaded cost). **These FTE figures are my estimates, not measured.** Replace them with your own. The model has a single `FTE` constant and a per-tier table.

---

## 3. Rate card used

| Item | Rate | Note |
|---|---|---|
| Logs ingest, Standard | $0.50/GB | flat for custom logs, no volume discount |
| Logs ingest, Infrequent Access / OTel "Essential" class | $0.25/GB | reduced feature set (section 5) |
| Logs storage | $0.03/GB-month | compressed |
| Logs Insights query | $0.005/GB scanned | |
| Live Tail | $0.01/min | first 1,800 min/month free |
| Data Protection | $0.12/GB scanned | on top of ingest |
| Cross-account/region log centralization | $0.05/GB | first copy free |
| OTel metrics ingest | $0.50/GB | includes 15 months storage, no per-series charge |
| Container Insights with OpenTelemetry (EKS) | $0.08/GB | much cheaper than app metrics |
| PromQL API / PromQL alarms | $0.01 per M samples scanned / $0.10 per alarm + scan | console and dashboards free |
| Spans (Transaction Search + Application Signals) | $0.35 → $0.20 → $0.15/GB (first 10 TB / next 20 TB / above) | 1% of spans indexed included, $0.75 per M spans beyond |
| Application Signals (signals only, no spans) | $1.50 → $0.75 → $0.30 per M signals | |
| X-Ray traces | $5 per M recorded | from the pricing-page examples |
| Alarm | $0.10 per metric, $0.50 composite | |
| Custom dashboard | $3/month | automatic dashboards are free |
| Custom metric (classic) | $0.30 → $0.02 per metric-month | tiered by volume |
| AMP | $0.90 per 10M samples (first 2B), $0.35 (next 250B), $0.16 beyond; $0.03/GB storage | |
| Amazon Managed Grafana | $9 editor, $5 viewer, $45 enterprise plugins, per user-month | |
| **CloudWatch investigations** | **no separate charge** | only small underlying API usage (AWS docs) |
| **AWS DevOps Agent** | **$0.0083 per agent-second** (about $0.50/min) | 2-month free trial; Support-plan credits |

---

## 4. Results: monthly cost

All figures are USD per month. "Infra" excludes people. Optional AI-agent usage is shown separately in section 7.

### 4.1 Infrastructure only

| App QPS | A1 Out-of-box | **A2 Tuned** | A3 Best case | **LGTM (repo + Grafana HA)** | Hybrid (LGTM + AWS-service signals) |
|---|---|---|---|---|---|
| 2,000 | $12,391 | **$1,889** | $967 | **$1,100** | $1,203 |
| 20,000 | $95,883 | **$15,204** | $7,341 | **$4,810** | $5,322 |
| 50,000 | $234,066 | **$33,542** | $17,250 | **$9,960** | $10,984 |
| 100,000 | $462,616 | **$62,755** | $32,127 | **$18,670** | $20,706 |
| 200,000 | $919,459 | **$120,543** | $60,728 | **$33,670** | $37,730 |

### 4.2 Including people cost

| App QPS | A2 Tuned | A3 Best case | **LGTM** | Hybrid | Cheapest all-in |
|---|---|---|---|---|---|
| 2,000 | **$2,639** | $1,717 | **$4,850** | $5,328 | AWS-native (A3) |
| 20,000 | **$16,704** | $8,841 | **$12,310** | $13,572 | AWS-native (A3); LGTM beats A2 |
| 50,000 | **$36,542** | $20,250 | **$24,960** | $27,484 | AWS-native (A3); LGTM beats A2 |
| 100,000 | **$67,255** | $36,627 | **$41,170** | $45,456 | AWS-native (A3); LGTM beats A2 |
| 200,000 | **$128,043** | $68,228 | **$63,670** | $70,730 | LGTM (7% under A3) |

**How to read this honestly:**

- **At 2K QPS, AWS-native wins** (about $2.6K vs $4.9K all-in) because LGTM's labour dwarfs its $1.1K infrastructure bill. The repo's own README agrees ("Stay with SaaS / CloudWatch").
- **LGTM beats a *tuned* CloudWatch (A2) from about 8K QPS upward**, by linear interpolation between my 2K and 20K points. I did not model the intermediate points.
- **LGTM does not beat a *best-case* CloudWatch (A3) on a full-labour basis until about 200K QPS.** Between 20K and 100K, A3 is 11–28% cheaper all-in. This is the finding that most changes the old README story.
- **LGTM wins clearly on pure infrastructure** at every scale above 2K (2–3.5x vs A2).
- **The A3 result depends on two asymmetries, both of which favour AWS-native:** (1) labour, where LGTM carries 0.5–2.0 FTE against 0.1–0.5 for AWS; and (2) log retention, where A3 keeps only 25% of log volume while LGTM keeps 100% on S3. Neutralizing each:

  | All-in, USD/mo | 20K | 50K | 100K | 200K |
  |---|---|---|---|---|
  | LGTM, 0.2 FTE marginal | $7,810 | $12,960 | $21,670 | $36,670 |
  | A2 tuned, 0.2 FTE | $18,204 | $36,542 | $65,755 | $123,543 |
  | A3 best case, 0.2 FTE | $10,341 | $20,250 | $35,127 | $63,728 |
  | A3 but keeping 100% of logs (IA class), 0.2 FTE | $20,032 | $44,479 | $83,586 | $160,645 |

  With equal labour, LGTM is cheaper than every AWS variant from 20K QPS up. With full log retention, even a best-case AWS setup costs roughly 3.5–4.7x LGTM on infrastructure ($17.0K vs $4.8K at 20K QPS; $157.6K vs $33.7K at 200K). The "AWS-native is cheaper all-in" result in the table above therefore needs *both* a dedicated platform team on the LGTM side *and* aggressive log dropping on the AWS side. This sensitivity was prompted by an independent review of the first version of this document.
- **If your platform team already exists and the marginal FTE is near zero,** LGTM wins everywhere above about 5K QPS. That is the case where this repo's numbers hold.

### 4.3 Where the A2 money goes

| Component | 2K | 20K | 50K | 100K | 200K |
|---|---|---|---|---|---|
| Traces (spans + indexing) | $718 | $5,704 | $10,985 | $18,898 | $34,724 |
| Logs (ingest + storage + scan) | $646 | $6,461 | $16,153 | $32,306 | $64,611 |
| Metrics | $76 | $1,118 | $2,494 | $3,812 | $6,386 |
| Dashboards + alarms | $20 | $90 | $200 | $330 | $600 |
| Collector fleet | $320 | $1,232 | $2,464 | $4,928 | $9,268 |
| PrivateLink transfer | $10 | $99 | $246 | $482 | $954 |
| AWS service signals (RDS, ALB, CloudTrail) | $100 | $500 | $1,000 | $2,000 | $4,000 |
| **Total** | **$1,889** | **$15,204** | **$33,542** | **$62,755** | **$120,543** |

**Logs are the largest line from 2K to 200K QPS.** That is where LGTM's S3-backed Loki is most advantageous, and where CloudWatch's $0.50/GB flat rate hurts most.

### 4.4 Metrics alone: CloudWatch OTel vs AMP vs self-hosted Mimir

CloudWatch's OTel metrics pricing is **by bytes, not by series**. That is cheap for low-frequency, high-cardinality data and expensive for dense, high-frequency data.

| QPS | Active series | Samples/month | AMP | CloudWatch OTel (60% via Container Insights) | CloudWatch OTel (all at $0.50/GB) | Repo Mimir (README) |
|---|---|---|---|---|---|---|
| 2K | 19K | 1.6B | $144 | $152 | $306 | ~$150 |
| 20K | 280K | 24.2B | $953 | $2,235 | $4,506 | ~$950 |
| 50K | 625K | 54.0B | $1,996 | $4,989 | $10,058 | ~$2,000 |
| 100K | 955K | 82.5B | $2,994 | $7,623 | $15,369 | ~$3,000 |
| 200K | 1.6M | 138.2B | $4,945 | $12,772 | $25,749 | n/a in README |

**Takeaway:** at a 30 s interval, **CloudWatch OTel metrics cost 2–5x AMP**. Its advantages are 15 months of retention, no cardinality limits, and no series bill. Use AMP or Mimir for bulk metrics unless cardinality explosions are your main problem. (Native histograms, which the draft recommends for AMP, are not modeled.)

---

## 5. Feature comparison

Legend: ✅ strong/native, 🟡 partial or needs work, ❌ not available out of the box.

### 5.1 Logs

| CloudWatch capability | AWS | LGTM + OTel | Notes |
|---|---|---|---|
| **Centralized collection** from EC2, Lambda, ECS, CloudTrail, custom apps | ✅ zero plumbing | 🟡 | Vended logs (ALB, VPC Flow, CloudTrail, Lambda) land in CloudWatch/S3 automatically. For LGTM you wire Firehose/S3 → collector. Collector-contrib has CloudWatch, Firehose, and S3 receivers; verify they are in your collector distro before relying on them. |
| **Real-time search / Live Tail** | ✅ $0.01/min after free tier | ✅ Grafana Explore live tail, `logcli --tail` | Equivalent for engineers; free in LGTM. |
| **Query and analysis** (Logs Insights QL, PPL, SQL) | ✅ | 🟡 LogQL | See section 8. |
| **Natural-language query generation** | ✅ Logs Insights and Metrics Insights, with explanation | ❌ | Verified in AWS docs. Could be replicated with an LLM + Grafana MCP, but you build it. |
| **Visualization** | ✅ automatic dashboards free, custom $3 | ✅ Grafana | Grafana is more flexible; CloudWatch is zero-effort. Grafana can also *read* CloudWatch. |
| **Alerting** (metric filters + alarms) | ✅ | ✅ Loki/Mimir ruler on LogQL, spanmetrics | Different mechanism, equivalent outcome. |
| **Log classes** (Standard vs Infrequent Access) | ✅ $0.50 vs $0.25/GB | n/a, S3 at ~$0.023/GB-month | IA has a reduced feature set (to my knowledge no Live Tail or metric filters; check current docs before depending on it). |
| **Log anomaly detection** (ML) | ✅ | ❌ | A real gap. Loki has pattern detection (`query_loki_patterns`) but that is not ML anomaly detection. |
| **Data Protection** (detect and mask sensitive data) | ✅ $0.12/GB scanned | 🟡 OTel `redaction` / `transform` processors | LGTM approach is *preventive*: redact at the gateway before storage, free, but you own the rules. CloudWatch's is managed detection with built-in identifier types. |
| **Metric filters** (logs → metrics) | ✅ | ✅ spanmetrics, count connector, Loki recording rules | |
| **Subscription filters** (stream logs elsewhere) | ✅ | ✅ OTel exporters and fan-out, Kafka buffer stub in repo | |
| **Integrations: OpenSearch, S3 Tables** (Iceberg/Athena SQL) | ✅ | 🟡 | Loki chunks on S3 are not queryable by Athena. Add an S3/Parquet exporter or use the repo's OpenSearch path. |
| **Cross-account / cross-region observability** | ✅ first copy free, $0.05/GB after | 🟡 | Multi-tenancy exists in the repo (`X-Scope-OrgID`), but cross-account pull is something you build. |
| **Contributor Insights** (top-N analysis) | ✅ | 🟡 LogQL `topk` / PromQL | Works, but manual. |

### 5.2 Everything else the diagram shows

| Capability | AWS | LGTM + OTel | Notes |
|---|---|---|---|
| Application Map / service graph | ✅ Application Signals | ✅ Tempo service graph + spanmetrics | Comparable; AWS needs no setup. |
| SLOs | ✅ Application Signals SLOs | ✅ Mimir ruler burn-rate rules (repo) | AWS has a UI; the repo has code. |
| Synthetics (canaries) | ✅ $0.0012/run | 🟡 Blackbox exporter / k6 | |
| Real User Monitoring | ✅ | 🟡 Grafana Faro (OSS SDK, you host) | |
| Container Insights (EKS) | ✅ $0.08/GB OTel mode | ✅ kube-state-metrics, cadvisor in repo | Same data source; AWS bills by GB. |
| Lambda / Database / Network / Internet Monitor | ✅ | ❌ | Native AWS-service telemetry. Use CloudWatch as a Grafana data source instead of rebuilding. |
| CloudTrail Insights / audit | ✅ | ❌ | Not an observability-stack job; keep in AWS. |
| Metric anomaly detection | ✅ | 🟡 | Recording rules plus `predict_linear`, no ML. |
| Composite alarms | ✅ $0.50 | ✅ Alertmanager inhibition/grouping | |
| eBPF auto-instrumentation | 🟡 | ✅ OBI in the repo's DaemonSet | |
| Tail sampling | 🟡 needs ADOT collector | ✅ repo Tier 3 | Same OSS processor; AWS-native just means you run it. |
| Multi-cloud / on-prem / local dev | ❌ | ✅ repo's local profile | CloudWatch only exists in AWS. |
| Data sovereignty / own the data | 🟡 | ✅ | |
| Vendor-neutral query languages | 🟡 PromQL on CloudWatch is new | ✅ PromQL / LogQL / TraceQL | |

**Net:** AWS wins on **zero-plumbing AWS coverage, log forensics, log ML, and managed sensitive-data detection**. LGTM wins on **cost at volume, portability, query-language standards, and flexibility of dashboards**.

---

## 6. AWS-native bill of materials: which services you actually need

"AWS-native" is not one product. This is the set of services a full CloudWatch-based setup on EKS pulls together. Items marked * are from my knowledge of AWS rather than from a page I fetched; confirm names and availability before building.

| Need | AWS service(s) | Notes |
|---|---|---|
| **Instrumentation** | OpenTelemetry SDKs / auto-instrumentation (same as today) | This layer is identical in both worlds. |
| **Collection agent** | AWS Distro for OpenTelemetry (ADOT) collector and/or the CloudWatch agent (both are in the AWS diagram). The "Amazon CloudWatch Observability" EKS add-on* installs the agent and enables Container Insights and Application Signals. | You still run a collector tier to sample and filter (section 2). |
| **Metrics: AWS services** | CloudWatch Metrics (basic monitoring is free) | ALB, RDS, Lambda metrics arrive on their own. |
| **Metrics: apps** | CloudWatch OTel metrics ingestion with PromQL ($0.50/GB), or AMP | CloudWatch is 2–5x AMP at 30 s resolution (section 4.4). |
| **Metrics: Kubernetes** | Container Insights with OpenTelemetry ($0.08/GB) or Enhanced Observability for EKS | The cheapest AWS metrics rate. |
| **Logs** | CloudWatch Logs; Fluent Bit or the CloudWatch agent as shipper | Log classes: Standard vs Infrequent Access. |
| **Log search and analytics** | CloudWatch Logs Insights (QL, PPL, SQL), Live Tail, field indexes*, Contributor Insights | $0.005/GB scanned. |
| **Log ML and masking** | Log Anomaly Detection, Data Protection | Data Protection is $0.12/GB scanned. |
| **Traces** | Application Signals + Transaction Search (spans stored in CloudWatch Logs), X-Ray | Priced per GB of spans, or per signal, or per trace (section 3). |
| **APM / service map / SLOs** | Application Signals | |
| **Dashboards** | CloudWatch dashboards (automatic ones are free); optional Amazon Managed Grafana | |
| **Alerting** | CloudWatch Alarms (metric, composite, anomaly, PromQL, log-query) → SNS or EventBridge → chat/pager | |
| **Synthetics / RUM / network** | CloudWatch Synthetics, RUM, Internet Monitor, Network Monitor | |
| **Audit** | CloudTrail, CloudTrail Insights | |
| **Cross-account** | CloudWatch cross-account observability (monitoring account + source accounts) | First copy free. |
| **AI: built into CloudWatch** | CloudWatch investigations; natural-language query generation and result summarization; anomaly detection | Investigations has no separate charge. |
| **AI: agent** | AWS DevOps Agent | $0.0083 per agent-second. Reads CloudWatch, S3, Grafana, Datadog, Splunk, New Relic, Dynatrace. |
| **AI: tool access (MCP)** | CloudWatch MCP, Application Signals MCP, CloudTrail MCP (named in the AWS diagram) | Let any MCP client (Amazon Q Developer CLI, Claude, others) query AWS telemetry. |
| **AI: chat and coding assistants** | Amazon Q Developer (operational investigations appear in CloudWatch); Amazon Bedrock for custom agents | |
| **GenAI app observability** | CloudWatch Generative AI observability (named in the diagram) | |
| **Cost control** | AWS Budgets and Cost Explorer on CloudWatch usage types | Without this, a debug-log flood is a direct bill. |
| **Identity** | EKS Pod Identity / IAM roles | Already used by this repo. |

**Minimum viable AWS-native stack for one EKS cluster:** ADOT collector + CloudWatch Logs + Container Insights (OTel) + Application Signals/Transaction Search + CloudWatch Alarms/SNS + dashboards. Add DevOps Agent only after the data is flowing.

---

## 7. AI and AIOps: AWS services vs. what you can do on LGTM

### 7.1 Can AWS's AI use our Loki and Tempo data?

**Yes for Loki; very likely for Tempo, but not confirmed by AWS's docs. Check it with a trial.**

What I verified:

| Fact | Source |
|---|---|
| AWS DevOps Agent has a built-in Grafana integration. It reads telemetry through Grafana's remote MCP server. It supports "any Grafana instance, including self-managed, Grafana Cloud, and Amazon Managed Grafana", and reaches the data sources configured there, named as "Prometheus, Loki, and OpenSearch". | AWS DevOps Agent GA announcement and "Connecting telemetry sources" docs |
| Private connections work for self-hosted Grafana and MCP servers. | Same GA announcement |
| Any other source, "including Prometheus metrics", can be connected by webhook or by registering your own MCP server. | "Connecting telemetry sources" docs |
| Grafana's open-source MCP server (`mcp-grafana`) exposes Loki tools (`query_loki_logs`, `query_loki_patterns`, label tools), Prometheus tools (`query_prometheus`), and **Tempo tools** (`search_tempo_traces` with TraceQL, `get_tempo_trace`, `query_tempo_metrics`, `diff_tempo_traces`). | Grafana MCP docs / GitHub |

What I could not confirm:

- **Whether DevOps Agent's built-in Grafana integration surfaces the Tempo tools.** AWS's text lists Prometheus, Loki and OpenSearch, not Tempo. Because the integration works through Grafana's MCP server, it probably does, but I have not seen it stated.
- **Fallback if it does not:** run `mcp-grafana` yourself and register it as a custom MCP server in DevOps Agent ("Connecting MCP Servers" in the docs). That route is documented.
- **How good the root-cause quality is** against Loki/Tempo data, and how many agent-seconds a noisy incident costs. Your own archive notes (`docs/aiops-portability-plan-archive.md`) rated DevOps Agent "weak for cross-service/app-level correlation across K8s + logs + traces". The Grafana integration may change that. Re-test it.

Mimir is Prometheus-compatible, so it is reachable through the same Prometheus data source.

### 7.2 AWS AI services at a glance

| Service | What it does | Cost | Works on your LGTM data? |
|---|---|---|---|
| **CloudWatch investigations** | AI-assisted root-cause hypotheses from CloudWatch telemetry; surfaces suggestions from metrics, logs, traces, deployments | No separate charge; minor API usage (AWS docs) | **No.** It reads AWS-native telemetry. |
| **AWS DevOps Agent** | Always-on agent: incident investigation, prevention evaluations ("Evaluations"), on-demand SRE chat, custom SRE agents; can trigger from alerts via webhook | $0.0083 per agent-second; 2-month trial; Support-plan credits | **Yes, via Grafana MCP** (7.1). |
| **CloudWatch / Application Signals / CloudTrail MCP servers** | Tool access for MCP clients | Underlying API usage | Only for AWS data. |
| **Natural-language query generation and summarization** | Writes Logs Insights / Metrics Insights / PPL / SQL from English, with line-by-line explanation | Included | No; CloudWatch Logs only. |
| **Log anomaly detection, metric anomaly detection** | ML baselines | Per alarm / included in Logs | No; data must be in CloudWatch. |
| **Amazon Q Developer** | Chat and CLI assistant; operational investigations in CloudWatch; can use MCP servers | See Q pricing | Via MCP only. |
| **Amazon DevOps Guru** | ML-based operational insights for AWS resources | Per resource-hour | No. Your archive notes mention it; check current availability and fit before relying on it. |
| **Amazon Bedrock** | Models and agent framework to build your own | Per token | Whatever you wire up. |
| **Generative AI observability** | Tracing and monitoring for LLM apps | CloudWatch rates | Separate concern. |

DevOps Agent usage at 8-minute investigations (optional, the same under every backend because it can read Grafana):

| QPS | 2K | 20K | 50K | 100K | 200K |
|---|---|---|---|---|---|
| Incidents/month assumed | 10 | 80 | 200 | 500 | 1,000 |
| Cost | $40 | $319 | $797 | $1,992 | $3,984 |

### 7.3 Do we have to use AWS AI services? No. What exists on the LGTM side

You can keep the data in LGTM and put the "brain" wherever you like. The data layer (Loki, Tempo, Mimir behind Grafana) is the part that matters; the AI layer is replaceable.

| Option | What it is | Status in this repo | Trade-off |
|---|---|---|---|
| **k8sgpt** | Zero-code cluster diagnosis | Deployed (`observability-as-a-product/aiops/demos/`) | Cluster state only, not logs/traces correlation |
| **HolmesGPT** | LLM investigation agent that queries Prometheus/Loki/K8s | Evaluation baseline deployed | You run it; bring your own LLM |
| **sre-agent-guardrails** | Your own autonomous SRE agent with guardrails; the repo ships read-only RBAC for it | In development | You own prompts, safety and on-call for the agent |
| **Grafana MCP server** | Lets any MCP client (Claude, Amazon Q, Cursor, DevOps Agent) query Loki, Tempo, Mimir, dashboards and alerts | Not wired yet | Needs a read-only service account and network path |
| **Robusta / Keep / OpenCost** | Playbooks, alert dedup, cost allocation | Evaluated in the archive notes, not adopted | Extra moving parts |
| **Grafana Cloud Sift / Grafana Assistant** | Managed investigation assistant | Not applicable to self-hosted OSS (per your archive notes) | Requires Grafana Cloud |
| **Alertmanager + pager AIOps** (PagerDuty etc.) | Event correlation and noise reduction | Alertmanager routing exists | Another SaaS |
| **DIY anomaly detection** | PromQL `predict_linear`, z-score recording rules, Loki patterns | Possible | No ML, you tune thresholds |

### 7.4 Where the AI runs vs. where the data lives

| Pattern | Data lives in | AI runs on | Good when |
|---|---|---|---|
| **A. All AWS** | CloudWatch | CloudWatch investigations + DevOps Agent | Small team, AWS-only, fast start |
| **B. LGTM + AWS AI** | Loki / Tempo / Mimir | DevOps Agent via Grafana MCP, plus CloudWatch for AWS resources | You want managed AI without moving data |
| **C. LGTM + own AI** | Loki / Tempo / Mimir | HolmesGPT / sre-agent-guardrails, any LLM (Bedrock included) | You need control, guardrails, custom runbooks, or non-AWS workloads |
| **D. Both** | Loki + a filtered slice in CloudWatch | DevOps Agent on both, k8sgpt/Holmes in-cluster | Mixed estates; most realistic for this repo |

**Honest take:** AWS's AI advantage is real inside AWS: it already understands your resources, deployments and CloudTrail. It is not exclusive to CloudWatch (pattern B), and the repo's own agent path (pattern C) gives you control at the cost of building and operating it. The deciding questions are who is accountable when the agent is wrong, and whether your incidents are mostly AWS-resource problems (favours AWS AI) or application-logic problems across services (favours having all signals in one queryable place, which is Grafana).

---

## 8. Log search

### 8.1 Options compared

| | CloudWatch Logs Insights | Loki (this repo) | OpenSearch (repo optional path) | Athena over S3 / S3 Tables |
|---|---|---|---|---|
| **Query language** | Logs Insights QL, PPL, SQL; natural-language generation | LogQL | Lucene / DSL / PPL | SQL |
| **Index model** | Scans log groups; field indexes can narrow scans* | Indexes labels only; content is grepped | Full inverted index | None (columnar scan) |
| **Best at** | Ad-hoc forensics across any field, no prior design | Fast on label-scoped queries ("this service, this pod, last hour"); cheap retention | Full-text and aggregations over long windows | Cheap bulk historic analysis and audits |
| **Weak at** | Cost grows with window and volume | Needle-in-haystack text over wide windows; high-cardinality labels | Cost and operations (indexing is heavy) | Not interactive |
| **Live tail** | ✅ ($0.01/min) | ✅ free | 🟡 | ❌ |
| **Cost to query** | $0.005/GB scanned | Included in compute | Included in cluster | Per TB scanned |
| **Ops** | None | You run it | You run it (repo has chart + ISM job) | Low |
| **Trace/metric correlation** | Application Signals / ServiceLens | Grafana derived fields, one click to Tempo | Grafana data source | Manual |

### 8.2 What a CloudWatch search actually costs

Logs Insights bills by data scanned, so cost depends on the time window. Using the tuned (A2) retained log volume at 20K QPS (about 25 TB/month, about 835 GB/day):

| Query window | Data scanned | Cost per query |
|---|---|---|
| 1 hour | about 35 GB | about $0.17 |
| 1 day | about 835 GB | about $4.20 |
| 7 days | about 5.7 TB | about $29 |
| 14 days (full retention) | about 11.7 TB | about $59 |

An engineer running ten 1-day searches during an incident spends about $42. A scheduled dashboard that scans 7 days every 5 minutes would cost over $8,000 a day, so treat log-query dashboards and log-query alarms as a budget item. Loki has no per-query charge; its cost is the fixed compute that runs it, but a wide free-text search is slower there.

### 8.3 Practical guidance

- **Day-to-day debugging of your own services:** Loki. Queries are label-scoped, fast, and free per query, and Grafana links a log line to its trace.
- **"Find this order ID / error string anywhere in the last two weeks":** this is where Loki is weakest. Use the OpenSearch path, or send a filtered slice to CloudWatch (section 10.3).
- **AWS-service logs (ALB, WAF, VPC Flow, CloudTrail, Lambda):** keep them in CloudWatch or S3 + Athena. Pulling them through Loki is plumbing you do not need.
- **Compliance and audit searches over months:** S3 + Athena (or S3 Tables) is the cheapest, not CloudWatch.
- **Sensitive data:** mask at the gateway (OTel `redaction`) so it never lands anywhere; add CloudWatch Data Protection only for log groups you cannot control upstream.

---

## 9. Making Grafana stable

### What the repo does today (verified in `grafana.yaml.tftpl`)

- `replicas: 1`
- `persistence.enabled: false`
- no `nodeSelector`/tolerations, so it can land on a spot node
- dashboards come from labelled ConfigMaps (good: reproducible)
- SLO alerts are evaluated by the **Mimir ruler**, not Grafana (good: an outage of the UI does not stop alerting)
- an out-of-band CloudWatch alarm + SNS topic watches NLB healthy targets (`terraform/modules/observability-stack/meta-monitoring.tf`, per `META_MONITORING.md`)

So a spot reclaim or OOM takes the UI down until the pod reschedules, and anything created through the UI (users, annotations, folders, API keys, ad-hoc dashboards) is lost at the same time.

### Fix list (cheapest first)

| # | Change | Why | Approx. cost |
|---|---|---|---|
| 1 | `replicas: 2` + `topologySpreadConstraints` across AZs + PodDisruptionBudget (`minAvailable: 1`) | Survives a node/AZ loss and drains | ~$20–40/mo |
| 2 | External Postgres (RDS `db.t4g.small`, Multi-AZ) for Grafana state | Required for >1 replica and for sessions, users and annotations | ~$60–120/mo |
| 3 | Pin Grafana to on-demand nodes | Stop spot reclaims taking the UI out | few dollars |
| 4 | Everything as code (dashboards, datasources, alert rules, folders) | Grafana becomes disposable; a rebuild takes minutes | free (partly done) |
| 5 | Extend meta-monitoring: add a canary on the Grafana ALB and alarms on gateway dropped spans / ingest lag, with SNS → pager | The NLB-targets alarm exists; Grafana reachability and ingest lag are not covered | ~$5–20/mo |
| 6 | Break-glass path: CloudWatch console, or a cold-standby Amazon Managed Grafana workspace with the same datasources | Last resort when the platform is the incident | ~$50–340/mo (seats) |
| 7 | Mimir ruler + Alertmanager HA (3 replicas) so alerting never depends on the UI | Mostly done | included |
| 8 | Backend resilience: zone-aware replication in Mimir/Loki/Tempo, WAL on PVC, S3 versioning | The real outage risk is ingesters, not Grafana | included in repo sizing |

The model's **Grafana HA add-on** is $100 → $500/month across tiers and covers items 1–3 and 5.

### Alternative: Amazon Managed Grafana

AMG ($9/editor, $5/viewer) removes the Grafana outage problem and can still query self-hosted Mimir/Loki/Tempo through a private connection. For 10 editors + 40 viewers that is $290/month, which is often cheaper than the labour of running HA Grafana. Trade-offs: less plugin and configuration freedom, and dashboards tie to an AWS account.

---

## 10. The hybrid approach in detail

### 10.1 This repo is already partly a hybrid

| Hybrid element | Status | Where |
|---|---|---|
| Grafana queries CloudWatch at read time (ALB, RDS metrics) via Pod Identity | **Done** | ADR 13, `docs/architectural-decisions.md` |
| Rejected: streaming all CloudWatch metrics into Mimir (Metric Streams + Firehose) | **Decided against, correctly** ($50–$300+/month for data nobody reads) | ADR 13 |
| Out-of-band CloudWatch alarm → SNS for total-cluster failure | **Done** | `meta-monitoring.tf`, `META_MONITORING.md` |
| Optional AMP instead of Mimir | **Available** | `use_amazon_managed_prometheus` |
| Dual-write of a filtered log slice to CloudWatch | Not done | — |
| Application Signals on critical services | Not done | — |
| Grafana MCP + DevOps Agent / CloudWatch MCP wiring | Not done | — |
| Highly available Grafana | Not done (section 9) | — |

### 10.2 Where each signal should live

| Signal | Home | Why |
|---|---|---|
| App traces | Tempo, tail-sampled | Volume-driven savings; tail sampling in Tier 3 |
| App logs | Loki | Cheapest retention; trace correlation in Grafana |
| App metrics | Mimir (or AMP) | 2–5x cheaper than CloudWatch OTel at 30 s |
| Kubernetes infra metrics | Mimir (Container Insights OTel only if you want the AWS console views) | |
| AWS service metrics (ALB, RDS, Lambda, DynamoDB) | **CloudWatch**, queried from Grafana | Free to produce; no plumbing (ADR 13) |
| Vended logs (ALB access, VPC Flow, WAF, CloudTrail) | **CloudWatch or S3 + Athena** | Native delivery |
| Audit | CloudTrail | |
| App SLO alerts | Mimir ruler | Already deployed |
| AWS-resource alarms | CloudWatch Alarms | Native |
| Meta-monitoring | CloudWatch + SNS (outside the cluster) | Different failure domain |
| Dashboards | Grafana primary; CloudWatch automatic dashboards for AWS services | |
| AI | DevOps Agent (Grafana MCP + built-in CloudWatch) and/or in-cluster Holmes/k8sgpt | Section 7.4 pattern D |

### 10.3 Optional additions, with cost

| Addition | What you get | Cost |
|---|---|---|
| **Error-slice dual write**: send only error/warn logs (3% of volume) to CloudWatch Standard | Log anomaly detection, Logs Insights, Data Protection and investigations on the high-value subset | at 2K → 200K QPS: about $75 / $750 / $1,900 / $3,800 / $7,500 per month + small storage |
| **Application Signals on a few critical services** | Service map, SLO UI, golden metrics, AI context | One service at 200 req/s with 2 dependencies (600 signals/s, 1.58 B/month) ≈ **$1,000/month** |
| **DevOps Agent** | Managed AI investigations over CloudWatch + Grafana | Section 7.2 table; trial first |
| **Amazon Managed Grafana** | No Grafana operations | About $290/month for 10 editors + 40 viewers |
| **S3 Parquet / S3 Tables export of logs** | Athena SQL over history | S3 + Athena scan costs |

Base hybrid cost from the model (LGTM + AWS-service signals, without the options above): $1,203 / $5,322 / $10,984 / $20,706 / $37,730 per month at 2K / 20K / 50K / 100K / 200K QPS.

### 10.4 What gets harder

- **Two alert paths** (Mimir ruler and CloudWatch Alarms). Keep a single routing destination (SNS → pager) and document which alerts live where.
- **Two query languages and two IAM surfaces.** Grafana's CloudWatch data source reduces the pain; it does not remove it.
- **Cost attribution is split** between S3/EKS (repo FinOps analyzer) and CloudWatch usage types. Tag consistently.
- **Trace IDs must be in logs** for correlation to work on either side. That is an instrumentation rule, not a platform feature.
- **Governance:** decide once which team owns CloudWatch spend, or the dual-write slice quietly grows.

### 10.5 Suggested adoption order

1. Fix Grafana HA and extend meta-monitoring (section 9). Cheap, removes the outage risk.
2. Confirm the CloudWatch data source dashboards cover AWS services (largely done, ADR 13).
3. Register Grafana MCP as a DevOps Agent source; run the 2-month trial against two or three real or simulated incidents. Measure root-cause quality and agent-seconds.
4. If log forensics or anomaly detection are the gap, dual-write the error slice and measure value against the $ in 10.3.
5. Re-run the cost model with your real GB/day and replace the labour assumptions.

---

## 11. Recommendations by application setup

| Setup | Recommendation | Why |
|---|---|---|
| **Serverless-heavy** (Lambda, API Gateway, DynamoDB, SQS) | **AWS-native** | Vended logs, Lambda Insights and X-Ray cover it without agents. Rebuilding that in LGTM is large. |
| **AWS-only, ECS/EC2, a few services, < ~8K QPS** | **AWS-native (A2)** | Cheaper once labour is counted; no platform team to hire. |
| **EKS microservices, 8K–50K QPS** (this repo's sweet spot) | **Hybrid** | LGTM for app telemetry, CloudWatch for AWS-managed service signals and meta-monitoring. Grafana reads both. |
| **EKS, > 50K QPS** | **LGTM, tuned (this repo)** | Infrastructure is 2–3.5x cheaper at volume and labour amortizes. |
| **Multi-account AWS organization** | **Hybrid** with CloudWatch cross-account observability for AWS-service signals | First copy is free; LGTM handles the volume-heavy app telemetry. |
| **Multi-cloud, on-prem, regulated or sovereign** | **LGTM** | CloudWatch only exists in AWS. |
| **AI/LLM workloads** | **Hybrid** | CloudWatch has Generative AI observability; the OTel GenAI semantic conventions are portable to either backend. |

---

## 12. Other considerations

| Topic | AWS-native | LGTM | Notes |
|---|---|---|---|
| **Lock-in and exit** | Instrumentation stays portable (OTel). Application Signals SLO definitions, Logs Insights queries and alarms are not. | Open formats and PromQL/LogQL/TraceQL | Keep CloudWatch config in Terraform so exit is a rewrite, not an archaeology project. |
| **Cost shape** | Cost follows volume directly: a debug-log flood is a bill | Cost follows capacity: a flood is a capacity problem (the repo's Kafka buffer exists for this) | Put AWS Budgets alerts on CloudWatch usage types on day one. |
| **Retention** | OTel metrics 15 months built in; logs per log-group setting | You configure and size it | |
| **Compliance** | KMS encryption, CloudTrail audit of access, Data Protection | You own every control | I did not verify specific certifications; check the AWS compliance programs page for your regime. |
| **Multi-tenancy / chargeback** | Account or log-group boundaries | `X-Scope-OrgID`, FinOps cost analyzer (repo) | |
| **Quotas and throttling** | Service quotas and API rate limits apply | You size and test capacity | Load test either way. |
| **Regional failure** | CloudWatch is regional | S3 with cross-region replication, plus a second cluster | The meta-monitoring in CloudWatch is a separate failure domain. |
| **Skills** | AWS skills; fewer specialists needed | Mimir/Loki/Tempo operations, a rarer skill set | A bus-factor risk for a small team. |
| **Time to first value** | Hours | Days to weeks (the repo shortens this) | |
| **Vendor roadmap** | AWS ships fast but changes names and pricing (OTel metrics and Application Signals pricing are new) | Upstream chart traps (see AGENTS.md) | |

---

## 13. What would change these conclusions

- **Your real GB/day.** Run three numbers through the model before deciding: log GB/day, spans/s, active series. Everything else is second-order.
- **Spans per request.** If your average request produces 3 spans rather than 8, A1/A2 trace costs shrink about 60%.
- **Log volume discipline.** Logs are the biggest AWS line. If you can cut log volume 75% (or move to the $0.25 class), CloudWatch gets much closer.
- **Real FTE cost.** If your loaded cost or on-call burden for a self-hosted stack is higher than 1 FTE at 50K QPS, AWS-native stays competitive further up.
- **AWS Enterprise Discount Program or Savings Plans.** Neither is modeled. Both reduce CloudWatch rates (and EC2 rates on the LGTM side).
- **DevOps Agent quality on your data.** If it resolves incidents well over Grafana, the case for building your own agent weakens.

---

## 14. Limits of this analysis

- I did **not** drive the interactive AWS Pricing Calculator UI. I used the AWS Price List API for the same rates and cross-checked it against the worked examples on the pricing page.
- **The CloudWatch cost lines are modeled, not measured.** Span size, log size, series counts, spans per request and sampling rates are assumptions (section 2). Real telemetry will differ, sometimes by 2x.
- **FTE numbers are estimates.** They drive the all-in comparison.
- **The LGTM figures are the repo's own** (README and `cost-calculation-draft.md`), plus my Grafana HA add-on. I did not independently re-derive them; I only checked that the AMP line reproduces.
- **SaaS comparison figures in the README (Datadog, Dynatrace, Grafana Cloud) were not re-verified.**
- **Not modeled:** data transfer to the internet, Lambda/Kinesis side-costs of investigations, Synthetics/RUM volumes, Database Insights per-vCPU charges beyond a flat allowance, S3 request costs on the LGTM side beyond the repo's numbers, enterprise-plugin Grafana seats, and EDP discounts.
- **Intermediate QPS values (for example 5K, 10K) are interpolated**, not computed.
- **Prices change.** Application Signals and OTel metrics pricing are new; re-run `aws-native-vs-lgtm-cost-model.py` against a fresh price list before a budget decision.
- **AI capabilities** are described from AWS and Grafana documentation, not from hands-on testing. Specifically unverified: Tempo reachability through DevOps Agent's built-in Grafana integration, root-cause quality on Loki/Tempo data, and agent-seconds on noisy incidents.
- **Items marked * in section 6 and the Infrequent Access feature limits** come from my background knowledge, not a page I fetched.
