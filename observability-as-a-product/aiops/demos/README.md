# AIOps Phase 1: k8sgpt Cluster Diagnosis Demo

This demo validates **[Phase 1 of the AIOps & Portability Plan](../../../docs/aiops-portability-plan-archive.md)**: evaluating open-source CNCF sandbox tool `k8sgpt` against the Kubernetes cluster before building custom agent tooling.

## Why k8sgpt (Build vs Adopt)

> **Interview Line:** *"I evaluated k8sgpt against the cluster before building anything custom — no point reimplementing AI-assisted `kubectl describe` when a maintained OSS tool already does it well."*

Standard Grafana dashboards will show higher error rates or failing pods, but cannot pinpoint:
1. Exact cgroup OOMKill events vs generic container crashes
2. Dial connection refused on misconfigured readiness probes
3. Recommended remediation steps in plain English

`k8sgpt` solves this zero-code diagnosis problem out of the box.

## Demo Scenario: Injected Faults

Using [`faulty-workloads.yaml`](faulty-workloads.yaml), two common production failure modes were simulated:
1. **OOMKilled Container:** `oomkill-product-service` specifies a `15Mi` memory limit while allocating `50Mi`, immediately triggering kernel OOM killer (exitCode 137).
2. **Broken Readiness Probe:** `probe-failure-service` specifies HTTP GET on port `8088` and path `/healthz-does-not-exist`, returning `connection refused` and leaving the pod in `0/1 Running` (unready).

## Results

### Raw Analyzer Output

Without requiring an external LLM key, `k8sgpt analyze` utilizes native AST analyzers to detect exact failure states:

```text
0: Pod aiops-demo/oomkill-product-service-654f6d8fdb-pxdch(Deployment/oomkill-product-service)
- Error: the last termination reason is OOMKilled container=memory-eater pod=oomkill-product-service-654f6d8fdb-pxdch

1: Pod aiops-demo/probe-failure-service-6798f958df-kp4lw(Deployment/probe-failure-service)
- Error: Readiness probe failed: Get "http://192.168.194.43:8088/healthz-does-not-exist": dial tcp 192.168.194.43:8088: connect: connection refused
```

### Full Session & JSON Output

- Terminal transcript: [`k8sgpt-terminal-session.md`](k8sgpt-terminal-session.md)
- Structured JSON output: [`k8sgpt-analysis.json`](k8sgpt-analysis.json)

## How to Reproduce

```bash
# 1. Install k8sgpt
brew install k8sgpt

# 2. Deploy the faulty workloads
kubectl create namespace aiops-demo
kubectl apply -f observability-as-a-product/aiops/demos/faulty-workloads.yaml

# 3. Run analysis
k8sgpt analyze -n aiops-demo --filter=Pod,Deployment --with-doc

# 4. Optional: Run with AI explanation
k8sgpt auth add --backend openai --model gpt-4o-mini
k8sgpt analyze -n aiops-demo --filter=Pod,Deployment --explain

# 5. Clean up
kubectl delete namespace aiops-demo
```
