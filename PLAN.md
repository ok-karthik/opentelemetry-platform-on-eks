# PLAN.md — Future platform mechanisms (profiling, automated rollback, cost allocation)

> **Executor instructions (read first).** This is a fresh plan, not a
> continuation of the closed AIOps/portability work — that's archived at
> [`docs/aiops-portability-plan-archive.md`](docs/aiops-portability-plan-archive.md)
> and stays untouched. Read `.agents/AGENTS.md` first (repo rules, chart
> traps, domain layout). Work through the phases in order — each is
> independent and can ship on its own, but Phase 3 touches the same
> "stable fault targets" contract `sre-agent-guardrails` depends on, so read
> its cross-repo note before touching `workloads/`. Do not commit or push
> unless the user asks.
>
> **Status (2026-09-26):** nothing in this file is built yet. All four
> phases were proposed as answers to "what would add real value next,"
> not requested features — confirm each is still wanted before starting.

## Goal

Four concrete platform additions, picked because each fills a gap the
closed AIOps work exposed rather than being AI for its own sake:

1. **Loki structured-metadata trace↔log correlation** — the click-through
   between Tempo and Loki already exists but is wired as a fragile text
   match against the log message body, not the indexed structured-metadata
   field it should be. Cheapest fix here, do it first.
2. **Pyroscope** — the golden-signals/traces/logs pillars exist; profiling
   (the fifth LGTM+P pillar) doesn't, and it's the difference between
   "this span is slow" and "here's why."
3. **Argo Rollouts** — a deterministic, non-AI mechanism that should own
   the single most common incident root cause (a bad deploy) automatically,
   so the AI agent's job narrows to the cases that actually need reasoning.
4. **OpenCost** — the FinOps agent (`cost-analyzer.py`) only measures
   observability-*pipeline* cost (ingestion volume). OpenCost measures
   workload *infra* cost (CPU/mem/node $) — a different, complementary
   signal, not a replacement.

Two things considered and explicitly **not** turned into phases here —
**Coroot** and **Keep** — because adopting them now would be duplicate
infrastructure without a proven gap. Their revisit triggers are in
["Watch, don't build yet"](#watch-dont-build-yet) below. **SigNoz/ClickHouse**
was also evaluated as an LGTM alternative and rejected for this repo
specifically (see the Landscape table in the archive) — not re-litigated here.

---

## Phase 1 — Loki structured-metadata trace↔log correlation

**Why now:** cheap, fast, and fixes a real click-through gap without
touching any storage backend. `terraform/modules/observability-stack/helm-values/loki.yaml.tftpl`
already sets `allow_structured_metadata: true` (schema v13/tsdb, required
for OTLP ingestion), and `grafana.yaml.tftpl` already wires Tempo↔Loki
linking — but the wiring is weaker than it looks:

- The Tempo datasource's `tracesToLogsV2.query` is
  `'{$${__tags}} |= "$${__trace.traceId}"'` — that's an **unindexed
  substring grep over the raw log message body**, not a structured-metadata
  filter. It only works if the app happens to print the trace ID as a
  literal string somewhere in the message text, in a format that survives
  whatever formatting that service's logger uses.
- The Loki datasource's `derivedFields` regex is `"trace_id=([a-f0-9]+)"`
  (unquoted hex right after `=`) — but the verified live log line from
  Phase 4 of the archived plan was `` `[Python App] Entering product_info
  handler...` `` with `trace_id="99d6b43aada7fb129161f8d1020d227f"`
  (**quoted**). That regex does not match a quoted value — the
  Loki→Tempo click-through direction for the Python service is likely
  silently broken right now. Verify this first before assuming either
  direction works.

- **1.1 Verify what's actually in structured metadata today.** In Grafana
  Explore, run `{service_name="python-product-info-service"} | trace_id
  != ""` (and the Go equivalent) against Loki directly. If `trace_id` is
  already present as structured metadata (likely, since it comes from the
  OTLP LogRecord's trace context via the gateway, independent of whatever
  the app also prints into the message text), the fix is query wiring, not
  a pipeline change.
- **1.2 Fix `tracesToLogsV2.query`** in `grafana.yaml.tftpl` to filter on
  the structured-metadata field instead of a body substring match:
  `'{$${__tags}} | trace_id="$${__trace.traceId}"'` — indexed, and no
  longer depends on the app's log message format at all.
- **1.3 Fix or drop the Loki `derivedFields` regex.** Either correct
  `matcherRegex` to handle the quoted format actually emitted
  (`trace_id="([a-f0-9]+)"`), or better: check whether the chart version in
  use supports deriving the link straight from structured metadata rather
  than a message regex, which removes the fragility entirely instead of
  just patching today's format.
- **1.4** If 1.1 finds a service where `trace_id` is *not* present in
  structured metadata (e.g. a future third service whose logging library
  doesn't propagate OTel trace context into its `LogRecord`), that's an
  app-instrumentation gap, not a Loki config gap — fix it at the SDK/logger
  level (e.g. Python's `opentelemetry-instrumentation-logging`), not by
  adding more regexes.
- **1.5 (cheap, do alongside)** Turn on Grafana **Correlations** config and
  check whether the installed Grafana version (10.5.15) already ships
  Explore Traces / Traces Drilldown, or needs the
  `grafana-exploretraces-app` plugin — this reduces click-hopping further
  without any backend change.

**Done when:** [ ] `{service_name=...} | trace_id="<real-id>"` returns the
correct log line for both demo services; clicking a span in Tempo jumps to
the exact matching log line (not a body-substring match); clicking a
`trace_id` in a Loki log line jumps to the correct Tempo trace, for both
Go and Python; the fragile regex/line-filter approach is gone from
`grafana.yaml.tftpl`.

---

## Phase 2 — Grafana Pyroscope (continuous profiling)

**Why now:** RCA today stops at "this span took 800ms." Profiling answers
*why* — which function, which lock, which allocation. It's a natural next
pillar because it's the same vendor (Grafana Labs), the same Helm-chart
pattern this repo already uses for Loki/Tempo/Mimir, and it plugs into the
same Grafana instance `mcp-grafana` already reads from.

- **2.1 Zero-app-code first.** Deploy Pyroscope's eBPF profiling agent
  (or Grafana Alloy's `pyroscope.ebpf` component) as a DaemonSet, the same
  zero-instrumentation pattern already used for OBI. This gets CPU
  flamegraphs per pod/node with **no changes to `workloads/golang-app` or
  `workloads/python-app`** — consistent with "adopt before you build."
- **2.2 Storage.** Self-hosted `pyroscope` Helm release, S3-backed, single
  replica, modeled on `terraform/modules/observability-stack/helm-charts.tf`'s
  existing loki/tempo/mimir pattern (own bucket, `nodeSelector: dedicated:
  monitoring-stateful`, same `s3_endpoint`/`s3_insecure`/`s3_force_path_style`
  variables already added for portability — reuse them, don't fork them).
  Add `pyroscope` to the `local.chart_versions` map next to the others.
- **2.3 Grafana wiring.** Add the Pyroscope datasource to
  `terraform/modules/observability-stack/helm-values/grafana.yaml.tftpl`
  next to `prometheus`/`loki`/`tempo`, with a stable UID (`pyroscope`) —
  match the naming convention `sre-agent-guardrails/docs/INTEGRATION.md`
  already documents for the other three, and add a row there too so the
  contract stays complete.
- **2.4 (stretch) Trace-to-profile correlation.** Once 2.1-2.3 work, add
  span-to-profile linking (Pyroscope's exemplar/span-selector support) for
  the two demo services — this is where an actual SDK-level change is
  needed (tagging spans with a profile ID), unlike 1.1's zero-code baseline.
- **2.5 Dashboard.** A new `observability-runtime/grafana-dashboards/12-continuous-profiling.yaml`,
  following the existing `NN-name.yaml` numbering convention.

**Done when:** [ ] Pyroscope pods Ready, S3-backed, portable via the same
`s3_endpoint`/`local-create` mechanism Phase 4 of the archived plan built;
a real flamegraph is visible in Grafana for `golang-product-service` under
induced load; `docs/INTEGRATION.md` lists the new datasource UID.

---

## Phase 3 — Argo Rollouts with metrics-based automated rollback

**Why now:** the AIOps work built an agent-readiness *diagnosis* contract.
This is the automated-*remediation* counterpart for the one root cause that
doesn't need an LLM at all: a bad deploy. Argo CD already exists in this repo
(`observability-as-a-product/argocd/`) — Rollouts is the natural next piece,
not a new GitOps investment.

- **3.1 Install the Argo Rollouts controller** (Helm, one namespace,
  read the existing `observability-as-a-product/argocd/README.md` for how
  this repo already structures Argo-family installs).
- **3.2 Convert `workloads/golang-app/golang-product-service.yaml` and
  `workloads/python-app/python-product-info-service.yaml`** from `kind:
  Deployment` to `kind: Rollout` (same PodSpec, same labels/selectors — a
  resource-kind change, not a redesign), with a canary strategy and an
  `AnalysisTemplate` that queries Mimir directly: the same
  `http_server_request_duration_seconds_count{..., http_response_status_code=~"5.."}`
  metric the SLO burn-rate alerts already use. A canary step that breaches
  the error-rate threshold auto-aborts and rolls back — no human, no agent,
  no LLM call, in the time it takes Mimir to evaluate one PromQL query.
- **3.3 Cross-repo RBAC note (do not skip):** `observability-runtime/sre-agent-rbac.yaml`
  grants `sre-agent-reader` read (`get`/`list`/`watch`) on `deployments`/
  `replicasets` in the `apps` API group only. A `Rollout` is a different
  CRD (`argoproj.io/v1alpha1`, kind `Rollout`) — without adding read
  access to that API group, the agent (and HolmesGPT) go blind on rollout
  status the moment 2.2 ships. Add it to the `ClusterRole` in the same
  session, and update `sre-agent-guardrails/docs/INTEGRATION.md`'s RBAC
  section to list the new resource — this is exactly the kind of drift the
  archived plan's "who owns what" rule exists to prevent.
- **3.4** Document in `docs/architectural-decisions.md`: why deterministic
  rollback for deploy-caused incidents, and AI-driven RCA for everything
  else, is the right split — not "AI does everything," not "AI does
  nothing."

**Done when:** [ ] a Rollout resource exists for both demo services; a
forced bad deploy (e.g. bump `PRODUCT_INFO_SERVICE_URL` to a broken value
inside the canary step) triggers an automatic abort+rollback, visible in
`kubectl argo rollouts get rollout` and as a Tempo/Loki-visible event; the
RBAC ClusterRole and `INTEGRATION.md` both list the `Rollout` resource.

---

## Phase 4 — OpenCost (real workload cost allocation)

**Why now:** `observability-as-a-product/aiops/finops/cost-analyzer.py`
only ever measures one signal — observability pipeline ingestion volume
(`otelcol_receiver_accepted_*`). It has no idea what a tenant's actual
compute costs. OpenCost (CNCF) is purpose-built for exactly that gap and
is a genuinely better tool for it than extending the hand-rolled script.

- **4.1** Install OpenCost (Helm), pointed at this cluster's node pricing
  (on-demand + spot, matches the `USE_SPOT` Makefile toggle already used
  for EKS node groups) and the existing `tenant.id`/namespace labels from
  `observability-as-a-product/onboarding/service-onboarding-contract.md`.
- **4.2** Extend `cost-analyzer.py` to pull real per-namespace/tenant
  infra cost from OpenCost's `/allocation` API **alongside** (not instead
  of) the existing ingestion-volume estimate — two independent cost
  signals in the same weekly report: "tenant X's *infra* cost is up 40%"
  vs. "tenant X's *telemetry* cost is up 200%" are different incidents
  with different fixes, and conflating them was the FinOps report's
  biggest blind spot.
- **4.3** Add an OpenCost row to `docs/multi-tenancy.md` / the FinOps
  section wherever tenant cost attribution is currently documented.

**Done when:** [ ] OpenCost pods Ready and returning real allocation data
for the two demo services' namespace; `weekly-cost-summary.md` shows both
the existing ingestion-volume figure and a real OpenCost infra-cost figure
side by side, generated from a single run, not two separate scripts.

---

## Watch, don't build yet

Not phases — conditions under which these get promoted to one.

- **Coroot** (eBPF service map / blast-radius RCA): revisit if
  `sre-agent-guardrails`' fault-injection eval (ROADMAP Step 5) shows the
  agent or HolmesGPT specifically struggle to *localize* root cause among
  several failing services, as opposed to just detecting that something's
  failing. If that's the weak score, add it as a read-only
  `observability-runtime/optional-extensions/` install — same pattern as
  `svc-nlb-otel-gateway.yaml`. Full reasoning: the archive's Landscape table.
- **Keep** (AIOps alert router): revisit only if the roadmap grows into
  correlating *non-observability* signals (deploy events, on-call
  schedules) into the alert path as a formal automated step, rather than
  leaving that check to the agent's own Argo CD sync-history read. Not
  worth it today — Alertmanager + SSM Incident Manager already cover
  dedup/escalation, and Phase 3 above already gives deploy-correlation to
  the *deterministic* rollback path for the one case that matters most.

## Explicitly out of scope here

- **SigNoz/ClickHouse migration** — evaluated, not planned. This repo's
  Mimir choice (AMP drop-in, PromQL-based SLO rules, `mcp-grafana`'s
  Prometheus/Loki/Tempo-typed toolset) is load-bearing across the whole
  agent-readiness contract; switching storage backends now would rewrite
  that contract for an ops-simplicity gain, not an RCA-quality one. See
  the archive's Landscape table for the full trade-off.
- **GenAI/LLM workload observability, IDP integration, Stage 2 GitOps
  migration** — already tracked in [`docs/future-roadmap.md`](docs/future-roadmap.md)
  Tracks 2-4. Not duplicated here.
