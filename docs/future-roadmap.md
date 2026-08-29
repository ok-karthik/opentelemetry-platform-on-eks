# Future Roadmap: AIOps, GenAI Observability & Platform Evolution

This document outlines the strategic roadmap for evolving this OpenTelemetry platform from a baseline infrastructure and microservice observability stack into an intelligent, AI-augmented telemetry platform.

---

## 1. Track 1: AIOps & Automated Incident Triaging (AI for Operations)

### The Problem
During production outages, on-call engineers suffer from **alert fatigue and tool-hopping**:
1. An alert fires in GoAlert ("Checkout service high error rate").
2. The engineer manually queries Prometheus/AMP to find which endpoint is failing.
3. The engineer hops to Loki to search for matching stack traces.
4. The engineer hops to Tempo to find slow spans or broken downstream dependencies.
5. The engineer runs `kubectl describe pod` to check for `OOMKilled`, scheduling failures, or node restarts.

This manual correlation adds 15–30 minutes of Mean Time to Detection/Resolution (MTTD/MTTR).

### The Solution: An In-Cluster Open-Source AIOps Copilot
Commercial platforms charge heavy premiums for AI correlation (Dynatrace Davis AI, Datadog Watchdog, AWS DevOps Guru). Because this platform standardizes all telemetry on **OpenTelemetry** with rich Kubernetes resource attributes, an open-source AIOps agent (such as **HolmesGPT** or **K8sGPT**) can automate the entire investigation loop.

#### Automated Investigation Workflow:
```text
[ Prometheus SLO Alert Fires (14.4x / 6x Burn Rate) ]
                      │
                      ▼
            [ GoAlert / Webhook ]
                      │
                      ▼
[ In-Cluster AIOps Investigation Agent (e.g. HolmesGPT) ]
  ├── 1. Query AMP (PromQL): Inspect metric anomalies and error rate spikes
  ├── 2. Query Loki (LogQL): Pull error logs matching the incident time window
  ├── 3. Query Tempo (TraceQL): Fetch error trace spans and downstream dependencies
  └── 4. Query EKS API: Run pod events, restart counts, and OOM status checks
                      │
                      ▼
     [ Enriched Slack / GoAlert Incident Summary ]
```

#### Example Output Posted to Engineers:
> **Root Cause Hypothesis (Confidence: 94%):**
> Pod `checkout-service-7f89d` was terminated with **Exit 137 (`OOMKilled`)** at 22:14:02 UTC.
> 
> - **Metrics:** Memory consumption exceeded the `512Mi` limit following a 4x spike in `/cart/checkout` requests.
> - **Logs:** Last error in Loki: `java.lang.OutOfMemoryError: Java heap space`.
> - **Traces:** 14 traces in Tempo show 504 Gateway Timeouts from `payment-service`.
> - **Recommended Remediation:** Increase container memory limit to `1Gi` in `workloads/k8s-manifests/checkout-service.yaml` and inspect payment service connection pooling.

---

## 2. Track 2: GenAI & LLM Workload Observability (Observability for AI)

### The Problem
When the microservices running on EKS are themselves GenAI applications (RAG pipelines, autonomous agents, LangChain/LlamaIndex services, or locally hosted vLLM models), **traditional APM metrics (HTTP 200 vs 500, wall-clock duration) become blind spots**:
* An HTTP 200 call can still be an expensive model failure (hallucination, toxic output, or empty context).
* Traditional tracing does not measure token usage, token velocity, or vector embedding latency.

### The New Metrics of LLM Telemetry
1. **Token Economics:** Prompt tokens, completion tokens, cached tokens, and USD cost attribution per team/tenant.
2. **Latency Breakdown:** Time-To-First-Token (TTFT) vs Inter-Token Latency (ITL) vs Vector DB retrieval duration.
3. **RAG & Context Quality:** Vector embedding search similarity scores (Qdrant/Milvus/pgvector), chunk relevance, and context precision.
4. **Agent Step Lifecycle:** Multi-turn tool-calling loops, retries, and guardrail evaluation scores.

### Architecture: Native OpenTelemetry GenAI Semantic Conventions
The OpenTelemetry project has standardized the **[GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)**:
- `gen_ai.system` (`openai`, `anthropic`, `gemini`, `vllm`)
- `gen_ai.request.model`
- `gen_ai.usage.prompt_tokens`
- `gen_ai.usage.completion_tokens`
- `gen_ai.response.finish_reasons`

```text
[ AI Workload (Python / Go) ]
  └── Auto-instrumented via OpenLLMetry / OTel GenAI SDK
            │ (OTLP with GenAI Spans)
            ▼
[ Regional OTel Gateway Fleet ]
  ├── 1. Standard Metrics ─────────> [ Amazon Managed Prometheus ]
  ├── 2. Infrastructure Traces ────> [ Grafana Tempo ]
  └── 3. LLM / Prompt Spans ───────> [ Self-Hosted Langfuse on EKS ]
```

### Key Tooling Evaluations:
* **[Langfuse](https://langfuse.com/) (Self-Hosted on EKS):** Open-source LLM engineering platform providing prompt management, playground, token cost attribution per tenant, and automated evaluation scores.
* **[OpenLLMetry](https://github.com/traceloop/openllmetry) (by Traceloop):** Extension of the OpenTelemetry SDK that auto-instruments OpenAI, Anthropic, LangChain, LlamaIndex, ChromaDB, and Pinecone directly into standard OTLP spans.
* **[Arize Phoenix](https://phoenix.arize.com/):** Open-source AI observability focused on RAG context retrieval, drift, and hallucination evaluations.

---

## 3. Track 3: Integration with Internal Developer Platform (IDP)

This repository functions as the **Observability Capability Pillar** inside a broader Internal Developer Platform (such as [internal-developer-platform](https://github.com/ok-karthik/internal-developer-platform) / Backstage):

```text
[ Internal Developer Platform (Backstage) ]
    │
    ├── Infrastructure Pillar   ──> Terraform / EKS Clusters / VPCs
    ├── Delivery Pillar         ──> Argo CD GitOps
    └── Observability Pillar    ──> THIS OpenTelemetry Platform!
```

### Integration Points:
1. **Backstage Software Templates (Golden Path):**
   - When an app developer scaffolds a new service in Backstage, the template automatically injects `telemetry.go` (Go) or OTel Operator pod annotations (Python/Java).
   - Automatically registers service metadata in `service-onboarding-contract.md` (`team`, `service.name`, `target_slo`).
2. **Backstage Service Catalog Plugin:**
   - Backstage entity pages automatically link directly to the service's **Grafana Golden Signals Dashboard**, **Tempo Trace Waterfall**, and **GoAlert Escalation Policy**.
3. **Production Readiness Scorecards:**
   - Checks if the service is emitting valid OTLP spans.
   - Checks if the service has configured multi-window SLO burn-rate alerts.
   - Verifies tenant tagging for FinOps cost allocation.

---

## 4. Track 4: Stage 2 GitOps Migration via Argo CD

Currently, base infrastructure is provisioned in Stage 1, while Helm charts are deployed in Stage 2 via Terraform. The next operational milestone will migrate Stage 2 to native Kubernetes GitOps:

1. **EKS GitOps Engine:** Enable EKS Managed Capabilities for Argo CD (`control-plane-argocd`).
2. **Argo CD App-of-Apps:** Point Argo CD to `observability-platform/argocd/` to declaratively reconcile:
   - cert-manager and OTel Operator
   - Loki, Tempo, and Grafana
   - Gateway manifests and routing policies
3. **Self-Healing & Drift Detection:** Any manual out-of-band changes to collector or backend configurations are automatically reconciled back to the git repository baseline.
