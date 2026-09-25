# PLAN.md — platform side: AIOps readiness, adopt baseline, FinOps, portability

> **Executor instructions (read first).** This file is the plan for this repo.
> Work through the phases **in order: 1 → 2 → 2b → 3 → 4**, one phase per session.
> Before writing anything, read `.agents/AGENTS.md` (repo rules and chart traps).
> Stop after each phase and tick its **Done when**. Do not start the agent itself
> here: it lives in `sre-agent-guardrails`. The only cross-repo duty is in
> "Who owns what": if you rename something `sre-agent-guardrails/docs/INTEGRATION.md`
> cites, update that file too. Do not commit or push unless the user asks.
>
> **Status (2026-09-25):** nothing in this file is built yet. The README
> "Portability" section describes the design; Phase 4 is what makes it tested.

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

## Phase 1 — AI cluster diagnosis, fastest win (~1-2 hrs)

Use **k8sgpt** (open source, CNCF sandbox) unmodified against the existing
cluster. Zero custom code, immediate result, shows you know the ecosystem
instead of reinventing it.

```bash
brew install k8sgpt
k8sgpt auth add --backend openai --model gpt-4o-mini   # or anthropic backend if supported
k8sgpt analyze --explain --filter=Pod,Deployment
```

Point it at the observability cluster (`make k8s-context` already sets this
up). Run it against a deliberately broken state (e.g. undersize a resource
limit) to get a clean before/after demo.

**Deliverable:** a terminal recording / screenshot showing k8sgpt catching
something the existing dashboards wouldn't surface in plain English (e.g. a
misconfigured probe or an OOMKill root cause), saved under
`observability-as-a-product/aiops/demos/`.

**Interview line:** "I evaluated k8sgpt against the cluster before building
anything custom — no point reimplementing AI-assisted `kubectl describe`
when a maintained OSS tool already does it well."

---

## Phase 2 — Agent-readiness contract (~2 hrs, platform-side only)

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
  (Go: `http_server_duration_milliseconds_*` legacy semconv; Python:
  `http_server_request_duration_seconds_*` stable semconv) are now part of the
  contract. Renaming any of them is a breaking change for the other repo.

**Done when:** every row of `sre-agent-guardrails/docs/INTEGRATION.md` is true
against this repo's `main`, and a firing burn-rate alert reaches both `alert-sink`
and a throwaway webhook on the agent URL.

## Phase 2b — HolmesGPT as the adopt baseline (~1-2 hrs)

The build-vs-adopt argument is only credible with numbers. Install **HolmesGPT**
(Robusta, OSS) read-only against the same Grafana datasources and the Phase 2.1
ServiceAccount, triggered manually. For each fault class in
`sre-agent-guardrails/docs/EVALUATION.md`, run HolmesGPT on the same injected fault
and record detected / localized / time-to-diagnosis. Those results become the
**adopt** column next to the custom agent and the human baseline in that repo's
results table. The results live there, not here; this repo only hosts the install.

**Interview line:** "I measured the OSS adopt option against my build on the same
faults, and here's where each one won."

---

## Phase 3 — FinOps / tenant cost-correlation agent (stretch, ~1-2 hrs)

Reuses the `tenant.id` routing already implemented in
`observability-as-a-product/gateway-policies/otel-gateway-multitenant.yaml`.

- Query Mimir/AMP for per-tenant series cardinality and ingest volume
  (`otelcol_receiver_accepted_*` grouped by `tenant.id`).
- Query S3 bucket growth (CloudWatch or `aws s3 ls --summarize`) for
  Loki/Tempo per-tenant prefixes if tenant-partitioned, or overall growth
  trend otherwise.
- Agent flags tenants with anomalous week-over-week growth and drafts a
  one-paragraph "why" using the same log/trace correlation tools from
  Phase 2 (e.g. "tenant X's log volume tripled — correlates with a new
  DEBUG-level logger merged in commit abc123").

**Deliverable:** a weekly-cost-summary markdown, generated on demand.

---

## Phase 4 — Portability profile: kind/k3d + MinIO (~half day, after Phases 1-3)

**Why:** the README "Portability" section says the Kubernetes layer runs anywhere.
This phase turns that from *designed to be* into *tested on*. It is also the
honest answer for on-prem and EU-sovereign-cloud interviews (STACKIT, IONOS,
OVHcloud, Hetzner are managed Kubernetes + S3-compatible storage, which is what
MinIO stands in for). **Do not** build Azure or GCP Terraform. One non-AWS profile
proves the seam.

- **4.1** Add `make local-create` / `local-destroy` (kind or k3d, one cluster)
  next to the existing `k8s-create`. Deploy MinIO (single-node, Helm) with
  buckets for Loki, Tempo, Mimir.
- **4.2** Render the **same** Helm values the Terraform module uses
  (`terraform/modules/observability-stack/helm-values/*.tftpl`) with a local
  values overlay. It sets the S3 endpoint to MinIO, `s3forcepathstyle`/`insecure`
  as each chart needs, and static keys from a Secret instead of Pod Identity.
  Avoid forking the values files. If a `.tftpl` hard-codes an AWS-only field,
  move that field into a template variable and document it.
- **4.3** Apply the same `observability-runtime/` manifests (gateways, ruler
  rules, dashboards) and `workloads/` demo apps. Skip `optional-extensions/svc-nlb-otel-gateway.yaml`,
  the CloudWatch datasource, and `10-aws-infrastructure-triage`. Mimir mode only
  (no AMP off AWS).
- **4.4** Update the README "Portability" **Status** line to say what actually ran,
  and add a `docs/portability.md` with any chart traps found (path-style S3,
  region strings MinIO ignores, etc.).

**Done when:** on a laptop, with no AWS credentials, both demo services show
golden signals in Grafana, a trace appears in Tempo, a log line in Loki, and a
forced 5xx spike fires a burn-rate alert into `alert-sink`. That also gives
`sre-agent-guardrails` a free local target for development (not for its eval,
which stays on the real platform).

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
| **Coroot** (`coroot/coroot`) | eBPF-based service map + golden signals + AI-assisted RCA, no code changes, self-hosted (Community Edition) | Fills the topology/blast-radius gap neither HolmesGPT nor a hand-built agent solves well on its own — the OSS equivalent of Dynatrace's Smartscape |
| **Keep** (keephq.dev) | OSS alerting + AIOps platform: alert deduplication, cross-tool correlation, workflow automation, has an AI copilot for investigation | Front-door alert router, not a competitor to Aurora/HolmesGPT — Keep dedups/routes, then invokes the RCA engine as a workflow step |
| **Robusta** (HolmesGPT's parent platform) | Playbooks-as-code: auto-triggered diagnosis + optional auto-remediation actions on K8s events | The "next level" once Phase 2 is proven — same team, same install, adds the auto-remediation trigger layer |
| **k8sgpt** (operator mode) | Same engine as Phase 1, but as an in-cluster operator that watches continuously instead of on-demand CLI runs | Natural Phase 1 -> Phase 2 bridge: switch from manual `k8sgpt analyze` to always-on |
| **OpenCost** (CNCF) | Real-time K8s cost allocation per namespace/label, not an LLM tool | Swap-in for the manual CloudWatch/S3 querying in Phase 3 — purpose-built for exactly that cost-attribution problem |

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
