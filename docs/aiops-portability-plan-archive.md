# PLAN Archive — AIOps Readiness, Adopt Baseline, FinOps, Portability

> **Archived Milestone Record.** All phases (1, 2, 2b, 3, and 4) in this plan were implemented, end-to-end verified, and closed on 2026-09-25.
> This document preserves the architectural decisions, cross-repo contract boundaries with `sre-agent-guardrails`,
> Guiding principles, and the build-vs-adopt evaluation matrix.
> Active operational rules and chart traps are maintained in [`.agents/AGENTS.md`](../.agents/AGENTS.md).
>
> **Status (2026-09-25):** All phases (1, 2, 2b, 3, and 4) are fully implemented and end-to-end verified — ticked and closed. Phase 4 functional verification on local cluster (Orbstack/MinIO) passed all 4 acceptance criteria: all pods Ready (Loki, Tempo, Mimir, Grafana), demo apps receiving traffic, traces/logs/metrics validated via Grafana datasource UIDs, and 5xx SLO burn-rate alerts evaluated by Mimir Ruler and delivered to alert-sink.
> All contract items in `sre-agent-guardrails/docs/INTEGRATION.md` are aligned with active code.

## Goal

Make this observability platform a good **target** for AI agents, and cover the
cheap "adopt" pieces here. The small, real AI-agent layer sits on top of what
already runs (Grafana, Mimir/AMP, Loki, Tempo, OBI eBPF, SSM Incident Manager,
Argo CD GitOps). It is not a platform rewrite. Each phase fits in a half-day session.

## Who owns what (decided 2026-09-25, read this first)

The custom guardrailed SRE agent (ADK, `grafana/mcp-grafana`, OPA tier gating,
Loki audit trail, Chaos Mesh + DeepEval scoring) is **built in
[`sre-agent-guardrails`](https://github.com/ok-karthik/sre-agent-guardrails)**, not here.
An earlier draft of this file had its own Phase 2 "build an RCA copilot" in this
repo. That was the same project twice, so it has moved there. **This file owns only:**

| Here (`opentelemetry-platform-on-eks`) | There (`sre-agent-guardrails`) |
|---|---|
| Phase 1: k8sgpt, unmodified, as the zero-code first look | The agent: Triage → Plan → RCA workers → Supervisor |
| Phase 2: the **agent-readiness contract** (RBAC, Grafana token, alert route, audit labels, stable fault targets) | Guardrail tiers (OPA), audit trail, trigger endpoint |
| Phase 2b: HolmesGPT as the **adopt baseline** it gets scored against | Fault injection + scoring (`docs/EVALUATION.md`) |
| Phase 3: FinOps / tenant cost correlation (a platform concern, uses `tenant.id`) | — |

`sre-agent-guardrails/docs/INTEGRATION.md` is the written contract between the
two repos. **Any change here that renames a namespace, datasource UID, alert
name, metric name, or file path it cites must update that file in the same
session.** It drifted once already (the `observability-platform` →
`observability-runtime` rename, the namespace moving from `monitoring` to
`observability`, and the collapse to one cluster). See `sre-agent-guardrails/PLAN.md`.

`internal-developer-platform` is **not** an agent target or a telemetry
dependency of either repo. Its ADR 0014 (IDP `PLAN.md` Phase 20) keeps a small
local SLO loop and can *optionally* forward OTLP to this platform's internal NLB.
When it does, IDP tenant services show up here like any other `tenant.id`. Treat
that as extra data, never a requirement.

**Why this shape and not a bigger one:** the point is to have 1-2 things you
built and can explain in depth in an interview, not a long feature list you
can only describe at the bullet-point level. Depth over breadth.

## Guiding principles (state these explicitly if asked in an interview —
they're the actual engineering judgment calls, not the code)

1. **Diagnosis is read-only.** Agents query Grafana/Prometheus/Loki/Tempo/
   kubectl through a read-only identity. Nothing in this repo grants an agent
   a write verb.
2. **Any write goes through a policy gate, never raw access.** The only agent
   allowed to act on this platform is `sre-agent-guardrails`, and only
   through its OPA tier table. Tier 0 is read-only; Tier 1-2 are small,
   reversible, audited actions; Tier 3 needs explicit, recorded human approval.
   Mechanical fixes still prefer a PR through the Argo CD GitOps flow over a
   live `kubectl apply`. Adopted tools (k8sgpt, HolmesGPT) run **read-only
   only**. That is the answer to "what stops the agent from making things worse."
3. **Agent output feeds the existing single pane, it doesn't create a
   second one.** RCA drafts, audit logs, and GenAI spans land in this repo's
   Loki/Tempo/Grafana and the SSM Incident Manager flow, not in a parallel
   dashboard or a new Slack app nobody else uses.
4. **Reuse what's already wired.** `tenant.id` routing, the 4-tier
   instrumentation model, and the gateway policies already in
   `observability-as-a-product/` are the join keys these agents use — don't
   re-invent tagging.

## Tools considered and not adopted

An older `AIOps.md` sketch (deleted, still in git history at `740b6f9`)
proposed Keep + Coroot + Aurora/HolmesGPT. It also named an "Odigos eBPF
agent" that this repo never ran; the eBPF component is **OBI**. Decisions:

- **Aurora (Arvo AI): not adopted.** It is a turnkey version of exactly what
  `sre-agent-guardrails` builds. Running both is the duplicate this plan
  exists to remove. Name it in interviews as the "adopt" option you weighed;
  HolmesGPT (Phase 2b) is the adopt option you actually *measure*.
- **Keep: not adopted.** Alertmanager already dedups and routes by `severity`,
  and SSM Incident Manager owns escalation. Keep would be a third alert router
  in front of the agent's webhook.
- **Coroot: deferred.** Its eBPF service map would answer "blast radius" better
  than trace sampling. But it is another node agent next to OBI on a ~$150/mo
  cluster. **Revisit** if `sre-agent-guardrails`' eval shows blast-radius
  localisation is the weak score. It would then join as one more read-only
  tool, installed here as an optional extension.

## Architecture

```
Alert fires (Mimir Ruler → Alertmanager)        or  manual "diagnose this"
        |                         \
        | severity=page|ticket     \--(continue: true)--> alert-sink / SSM Incident Manager (unchanged)
        v
  sre-agent-guardrails trigger  ──> Triage → Plan → RCA workers → Supervisor
        |                                   |
        |   read-only, via mcp-grafana      +--> OPA tier gate (before any write tool)
        +-- PromQL (Mimir/AMP), LogQL (Loki), TraceQL (Tempo)
        +-- K8s MCP server, read-only SA (events, describe, logs)
        +-- Argo CD sync history / git log (did a deploy land in the window?)
        |
        v
  Structured diagnosis → audit + GenAI spans into this repo's Loki/Tempo,
  summary to SSM Incident Manager, draft PR if the fix is mechanical
```

k8sgpt (Phase 1) and HolmesGPT (Phase 2b) hit the same read-only surface,
manually triggered, so all three can be compared on the same faults.

---

## Phase 1 — AI cluster diagnosis, fastest win ✅ done

Used **k8sgpt** (OSS, CNCF sandbox) unmodified against the cluster — zero
custom code. Injected an OOMKilled pod and a broken readiness probe, then
confirmed `k8sgpt analyze` catches both in plain English.

**Deliverables:** [`k8sgpt-terminal-session.md`](../observability-as-a-product/aiops/demos/k8sgpt-terminal-session.md), [`k8sgpt-analysis.json`](../observability-as-a-product/aiops/demos/k8sgpt-analysis.json), under `observability-as-a-product/aiops/demos/`.

**Interview line:** "I evaluated k8sgpt against the cluster before building
anything custom — no point reimplementing AI-assisted `kubectl describe`
when a maintained OSS tool already does it well."

---

## Phase 2 — Agent-readiness contract ✅ done (kept in full — this section is the live contract `sre-agent-guardrails` reads against, not just a todo list)

Everything `sre-agent-guardrails` ROADMAP Steps 1-3 need from **this** repo,
and nothing else. No agent code lands here. Each item is a small change in this
repo plus a matching line in `sre-agent-guardrails/docs/INTEGRATION.md`.

- **2.1 Read-only agent identity.** A `ServiceAccount` + `ClusterRole` with only
  `get`/`list`/`watch` on `pods`, `pods/log`, `events`, `deployments`,
  `replicasets`, `nodes`. Bound in `default` (demo apps) and `observability`.
  Model the shape on `otel-collector-agent-role` in
  `workloads/otel-collector-daemonset.yaml`, minus anything but read. Prove it with
  `kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa>`. Do not trust the YAML.
- **2.2 Grafana service account for `mcp-grafana`.** `Viewer` role, token kept
  in a Secret (not in git). Record the three datasource UIDs it will use
  (`prometheus`, `loki`, `tempo` in
  `terraform/modules/observability-stack/helm-values/grafana.yaml.tftpl`).
  **Mimir mode only:** with `use_amazon_managed_prometheus = true` there are no
  ruler rules, so no burn-rate alerts fire and the agent has no trigger. Say so
  in the contract; do not paper over it.
  **Also fix a doc/code mismatch:** the README "Decisions and Trade-Offs" row
  *Telemetry Backends* says "Serverless AMP" was chosen, but Terraform defaults to
  Mimir (`use_amazon_managed_prometheus = false`). Make the README match the code:
  Mimir is the default, and AMP is an opt-in that loses the ruler-based SLO alerts
  until rule groups are ported to `aws_prometheus_rule_group_namespace`. Do not
  flip the Terraform default.
- **2.3 Alert route to the agent, additive.** In `mimir.yaml.tftpl`
  `alertmanager.fallbackConfig`, add a route/receiver for the agent's trigger URL
  **with `continue: true`**, ahead of the existing `alert-sink` and SSM routes.
  Match only `severity=~"page|ticket"`. `ObservabilityPipelineWatchdogHeartbeat`
  (`severity: heartbeat`) always fires, and would start an agent run every
  repeat interval.
  Keep those routes. A broken or slow agent must never swallow a page. Gate the
  receiver behind a Terraform variable (`enable_sre_agent_webhook`, default `false`)
  so the platform deploys cleanly without the agent.
- **2.4 Audit/GenAI labels.** Reserve `service.name=sre-agent` and
  `tenant.id=platform-aiops` for the agent's Loki audit stream and Tempo GenAI
  spans. They then go through the existing gateway `tenant.id` routing and show up
  in Grafana next to the demo services. No new pipeline.
- **2.5 Stable fault targets.** `golang-product-service` and
  `python-product-info-service` in `default` (`workloads/golang-app`,
  `workloads/python-app`) are the eval's fault targets. Their env levers
  (`PRODUCT_INFO_SERVICE_URL`, `PORT`, resource limits) and SLO metric names
  (both Go and Python emit `http_server_request_duration_seconds_*` stable semconv;
  Go explicitly sets `OTEL_SEMCONV_STABILITY_OPT_IN=http`) are now part of the
  contract. Renaming any of them is a breaking change for the other repo.

**Done when:** [x] every row of `sre-agent-guardrails/docs/INTEGRATION.md` is true
against this repo's `main`, read-only RBAC manifest created at `observability-runtime/sre-agent-rbac.yaml`,
additive alert route with `continue: true` added to `mimir.yaml.tftpl`, reserved labels `service.name=sre-agent`/`tenant.id=platform-aiops`
documented in `service-onboarding-contract.md`, and stable fault targets verified.

## Phase 2b — HolmesGPT as the adopt baseline ✅ done

Installed **HolmesGPT** (Robusta, OSS) read-only via `uv tool run --from holmesgpt holmes`,
pointed at the same Grafana datasources and the Phase 2.1 read-only ServiceAccount.
Config, in-cluster deployment manifest, and a CLI runner live in
`observability-as-a-product/aiops/holmesgpt/`. Scoring HolmesGPT against each
fault class in `sre-agent-guardrails/docs/EVALUATION.md` (detected / localized /
time-to-diagnosis) — the actual **adopt** column in that repo's results table —
is `sre-agent-guardrails`' job, not this repo's; this repo only hosts the install.

**Interview line:** "I measured the OSS adopt option against my build on the same
faults, and here's where each one won."

---

## Phase 3 — FinOps / tenant cost-correlation agent ✅ done

`observability-as-a-product/aiops/finops/cost-analyzer.py` queries Mimir for
per-tenant ingest volume (`otelcol_receiver_accepted_*` by `tenant_id`), parses
the real PromQL vector response, flags anomalous week-over-week growth, and
generates [`weekly-cost-summary.md`](../observability-as-a-product/aiops/finops/weekly-cost-summary.md).
Falls back to a clearly-labeled `--simulate` baseline dataset when Mimir is
unreachable or has no data yet — it does not silently fabricate a "live" result.
Verified with an automated unit suite ([`test_cost_analyzer.py`](../observability-as-a-product/aiops/finops/test_cost_analyzer.py))
that exercises live-vector parsing, connection-failure fallback, and `--simulate`.

---

## Phase 4 — Portability profile: kind/k3d/orbstack + MinIO ✅ done

**Why:** the README "Portability" section says the Kubernetes layer runs anywhere.
This phase turns that from *designed to be* into *tested on*. It is also the
honest answer for on-prem and EU-sovereign-cloud interviews (STACKIT, IONOS,
OVHcloud, Hetzner are managed Kubernetes + S3-compatible storage, which is what
MinIO stands in for).

**Built and verified (infra/rendering level):**
- `make local-create` / `make local-destroy` (kind/k3d/orbstack), deploying MinIO
  with automated bucket provisioning for Loki/Tempo/Mimir.
- Real Terraform variables (`s3_endpoint`, `s3_insecure`, `s3_force_path_style`,
  unified across all three charts) wired through `main.tf` → `helm-charts.tf` →
  the `.tftpl` files — no more AWS-only hardcoded endpoints.
- `terraform/local/render/main.tf` calls Terraform's actual `templatefile()` (via
  `terraform/local/render-values.py`) to render the exact same base values — zero
  hand-rolled template parsing.
- `terraform fmt -check` / `terraform validate` / `make helm-lint` all pass.
- On a live local cluster: `gp3` StorageClass aliased to the local provisioner,
  MinIO + bucket-init job come up, cert-manager and the OTel Operator install,
  and the Loki pod schedules with its PVC bound.
- Details and chart traps: [`portability.md`](./portability.md).

**End-to-end functional verification passed (2026-09-25):**
1. **Pod Health:** All 24+ observability and workload pods reach `Running` / `Ready` (`loki-0` 2/2, `tempo-0` 1/1, all 10 Mimir microservices 1/1, `grafana` 2/2, SRE `alert-sink` 1/1).
2. **Workload Traffic:** `golang-product-service` and `python-product-info-service` deployed cleanly, receiving inter-service requests with context propagation over W3C traceparent headers.
3. **Grafana Datasource Telemetry Verified:**
   - **Tempo (`uid: tempo`):** Distributed trace ID `2e9bc6259f0941aeda54965c7b2bfc2c` spanning `golang-product-service` (`GET /product`, 142ms) down to `python-product-info-service` (`GET /product-info`).
   - **Loki (`uid: loki`):** Log stream `{service_name="python-product-info-service"}` recording `"[Python App] Entering product_info handler..."` with correlated `trace_id="99d6b43aada7fb129161f8d1020d227f"`.
   - **Mimir (`uid: prometheus`):** Golden signal metrics actively received and queried: `http_server_request_duration_seconds_count{job="product/golang-product-service", http_route="/product"}` and `traces_span_metrics_calls_total`.
4. **Alerting & Escalation to `alert-sink`:**
   - Induced 5xx error rate spike via misconfigured `PRODUCT_INFO_SERVICE_URL="http://127.0.0.1:9999"` (100% failure rate).
   - Mimir Ruler evaluated `GolangProductServiceErrorBudgetBurnFast` (14.4x burn rate over 1h and 5m windows) with `status=success`, transitioning the alert to `firing`.
   - Alertmanager successfully routed and delivered the webhook payload (`receiver: aws-incident-manager`, `status: firing`, `alertname: GolangProductServiceErrorBudgetBurnFast`, `severity: page`) directly to `http://alert-sink.observability.svc.cluster.local:8080/webhook`.

That gives `sre-agent-guardrails` a free local target for development once
closed out (not for its eval, which stays on the real platform).

---

## Explicitly out of scope for now (mention as "next" in an interview, don't build)

- **Autonomous CVE-to-PR remediation** — valuable, but needs a real policy
  layer (what's auto-mergeable vs. what needs review) that's its own
  half-day. Natural Phase 4 once Phase 2's PR-drafting pattern exists,
  since it reuses the same "propose a PR, don't auto-apply" mechanism.
- **On-demand ephemeral dev environments** — this repo's `make k8s-create`
  / `SINGLE_CLUSTER` toggle is already most of the mechanism; wrapping it
  behind an agent that provisions a scoped namespace on request is real
  but separate scope from RCA/AIOps.

## What to be ready to explain in an interview

- Why diagnosis is read-only and remediation is propose-only (safety /
  blast-radius reasoning, not just "best practice").
- Why you evaluated k8sgpt/HolmesGPT before building custom (build vs.
  adopt judgment).
- Why the agent's output lands in the existing Grafana/SSM/Git flow
  instead of a new dashboard (avoiding observability fragmentation — this
  is the same "single pane" argument from the platform's own design).
- One concrete run: a real injected failure, the exact tool calls the
  agent made, and the RCA it produced — this is the part that
  differentiates you from a bullet-point resume claim.

## Reference tools

- k8sgpt — https://k8sgpt.ai (OSS, CNCF sandbox, AI-powered K8s diagnosis)
- kubectl-ai — Google, natural-language kubectl
- HolmesGPT — Robusta, OSS multi-source AIOps root cause engine
- Grafana MCP server — github.com/grafana/mcp-grafana

---

## Landscape: build vs. adopt, open source and enterprise

Knowing this landscape and being able to contrast it is itself interview
signal — separate from what you actually build. Framing for the answer:
"I looked at build-it-yourself, open-source-platform, and enterprise SaaS,
and picked X because Y" is a stronger answer than only knowing the vendor
tool you happened to have licensed at your last job.

### Open source alternatives (self-hosted, you control the data path)

| Tool | What it actually does | Where it fits vs. HolmesGPT |
|---|---|---|
| **Aurora** (Arvo AI, `Arvo-AI/aurora`) | Apache 2.0, LangGraph-orchestrated agentic incident investigation across AWS/Azure/GCP/K8s, 30+ tool integrations, built-in vector store of past postmortems, generates postmortems and draft remediation PRs | Most turnkey option — covers nearly all of what `sre-agent-guardrails` builds. **Not adopted** (see "Tools considered and not adopted"); name it as the adopt option weighed |
| **HolmesGPT** (Robusta) | Multi-source root cause: pulls Prometheus/Loki/Tempo/K8s events into one LLM investigation, K8s-native | **Adopted as the measured baseline** (Phase 2b) — read-only, scored on the same faults as the custom agent |
| **Coroot** (`coroot/coroot`) | eBPF-based service map + golden signals + AI-assisted RCA, no code changes, self-hosted (Community Edition) | Fills the topology/blast-radius gap neither HolmesGPT nor a hand-built agent solves well on its own — the OSS equivalent of Dynatrace's Smartscape. **Deferred, not rejected — revisit trigger:** if `sre-agent-guardrails`' fault-injection eval (ROADMAP Step 5) shows the agent/HolmesGPT specifically struggle to localize the root cause among several failing services (vs. just detecting *that* something is failing), add Coroot as a read-only `optional-extensions/` install — same low-blast-radius pattern already used for `svc-nlb-otel-gateway.yaml` |
| **Keep** (keephq.dev) | OSS alerting + AIOps platform: alert deduplication, cross-tool correlation, workflow automation, has an AI copilot for investigation | Front-door alert router, not a competitor to Aurora/HolmesGPT — Keep dedups/routes, then invokes the RCA engine as a workflow step. **Not adopted, low priority to revisit:** Alertmanager (`severity` routing) and AWS SSM Incident Manager already cover dedup/escalation, so Keep would be a third router with no new capability today. Only reconsider if the roadmap grows into correlating *non-observability* signals into the alert path (e.g. "this page correlates with the deploy that landed 4 minutes ago" as an automated pre-agent step) rather than leaving that check to the agent itself |
| **Robusta** (HolmesGPT's parent platform) | Playbooks-as-code: auto-triggered diagnosis + optional auto-remediation actions on K8s events | The "next level" once Phase 2 is proven — same team, same install, adds the auto-remediation trigger layer |
| **k8sgpt** (operator mode) | Same engine as Phase 1, but as an in-cluster operator that watches continuously instead of on-demand CLI runs | Natural Phase 1 -> Phase 2 bridge: switch from manual `k8sgpt analyze` to always-on |
| **OpenCost** (CNCF) | Real-time K8s cost allocation per namespace/label, not an LLM tool | Swap-in for the manual CloudWatch/S3 querying in Phase 3 — purpose-built for exactly that cost-attribution problem |
| **SigNoz** (`SigNoz/signoz`, ClickHouse-backed) | OTel-native APM: traces, metrics, and logs all stored in a single ClickHouse columnar database, own UI, single query engine instead of PromQL/LogQL/TraceQL glued together via Grafana Explore | **Not adopted — a real architectural alternative, but not for this repo.** Genuinely simpler ops (one stateful backend vs. Mimir+Loki+Tempo's three), and better native cross-signal correlation. But this platform's Mimir choice is load-bearing (AMP drop-in via `use_amazon_managed_prometheus`, PromQL-based SLO rules, `mcp-grafana`'s Prometheus/Loki/Tempo-typed toolset that the agent's entire read surface depends on) — switching would rewrite the Phase 2 contract, not just the storage layer. Worth naming as "what I'd seriously evaluate building this from scratch today with no AMP/PromQL requirement," not as a migration plan |

### Enterprise / cloud / SaaS (buy vs. build)

| Product | Category | Notes |
|---|---|---|
| **Dynatrace Davis AI** | Deterministic causal AI (not LLM-based correlation) over Smartscape topology | You already know this one — good contrast point: Davis is causal/topology-based and deterministic, HolmesGPT-style tools are LLM-based and probabilistic. Different failure modes, worth naming the distinction in an interview |
| **Datadog Bits AI / Watchdog** | LLM-based investigation agent + automatic anomaly detection, native to Datadog's stack | Direct SaaS competitor to what Phase 2 builds, if already on Datadog |
| **New Relic AI** | Similar LLM-assisted investigation inside New Relic's platform | Same category as Datadog Bits AI |
| **Grafana Cloud "Sift" / Grafana Assistant** | Automated investigation assistant built into Grafana Cloud | Most relevant to *this repo specifically* since you already run OSS Grafana — natural upsell path if the org ever moves to Grafana Cloud, and a good "I know the managed equivalent of what I built" line |
| **BigPanda / Moogsoft** | Event correlation & noise-reduction specialists, tool-agnostic across the whole ITOps stack | Enterprise-scale alert correlation across many disparate tools, not K8s-specific — different problem shape than HolmesGPT |
| **PagerDuty AIOps / PagerDuty Advance** | Event intelligence, correlation, auto-drafted postmortems | Overlaps with Phase 2's output goal (auto-drafted RCA/postmortem) — if the org already pays for PagerDuty, this may make Phase 2 partially redundant, worth checking before building |
| **Causely** | Causal AIOps, K8s-native, newer entrant (post-2023) | Closest philosophical match to Dynatrace's causal approach but K8s-native and newer — good one to name if asked "what's emerging in this space" |
| **AWS-native: Amazon Q + DevOps Guru + CloudWatch anomaly detection** | ML-based anomaly detection and RCA scoped to AWS resources (RDS, Lambda, ECS, etc.) | The AWS DevOps Agent you already used sits here — good to explicitly place it: strong for AWS-resource-level anomalies, weak for cross-service/app-level correlation across K8s + logs + traces, which is the gap HolmesGPT/Phase 2 fills |

**One-line summary if asked "why not just buy this":** the enterprise tools
are strong at topology-aware or AWS-resource-level RCA out of the box, but
none of them are free, and building the narrow OSS version yourself is what
proves you understand the mechanism instead of just operating someone
else's black box — which is the actual gap this plan is closing.
