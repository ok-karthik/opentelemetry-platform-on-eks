# AIOps Phase 2b: HolmesGPT as the Adopt Baseline

This directory hosts the deployment and configuration for **HolmesGPT** (Robusta, OSS), serving as the measured **Adopt Baseline** evaluated against our custom guardrailed agent in [`sre-agent-guardrails`](https://github.com/ok-karthik/sre-agent-guardrails) *(in development)*.

## Why HolmesGPT (The Adopt Baseline)

> **Interview Line:** *"I measured the OSS adopt option against my build on the same faults, and here's where each one won."*

Rather than comparing custom tooling against an imaginary strawman, HolmesGPT provides a rigorous, industry-standard baseline:
- Connects directly to Prometheus/Mimir, Loki, Tempo, and Kubernetes API.
- Executes multi-step investigative tool calls to synthesize an RCA summary.
- Runs strictly **read-only** with no remediation execution.

## Platform Integration Seam

1. **Kubernetes Identity:** Bound to `sre-agent-reader` ServiceAccount ([`observability-runtime/sre-agent-rbac.yaml`](../../observability-runtime/sre-agent-rbac.yaml)), which grants strictly `get`/`list`/`watch` on pods, logs, events, deployments, and nodes.
2. **Prometheus / Mimir:** Queries `http://mimir-gateway.observability.svc.cluster.local./prometheus`.
3. **Loki Logs:** Queries `http://loki.observability.svc.cluster.local.:3100`.
4. **Tempo Traces:** Queries `http://tempo.observability.svc.cluster.local.:3200`.

## Running HolmesGPT

### 1. In-Cluster Read-Only Deployment

Deploy the pre-configured HolmesGPT pod to namespace `observability`:

```bash
kubectl apply -f observability-as-a-product/aiops/holmesgpt/holmes-deployment.yaml
```

### 2. Local CLI Investigation (via uv)

You can run HolmesGPT against an active port-forward (`make k8s-dashboards`) or alert payload:

```bash
# Execute against a sample burn-rate alert payload
./observability-as-a-product/aiops/holmesgpt/run-investigation.sh
```

## Fault Scoring & Evaluation

Evaluation results across the five fault classes defined in `sre-agent-guardrails/docs/EVALUATION.md` (Detection Accuracy, Localization MTTR, and RCA completeness) are tracked in the comparison table of `sre-agent-guardrails`.
