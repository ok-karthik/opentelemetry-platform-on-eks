# OpenTelemetry Observability Platform on EKS

Reference implementation of a multi-cluster observability platform on Amazon EKS. Application teams emit traces, metrics, and logs through OpenTelemetry Collectors into a dedicated observability cluster, while the platform team owns routing, sampling, dashboards, and cost controls.

The telemetry path, end to end:

1. A Go service calls a Python service and propagates W3C trace context.
2. A workload-cluster OTel Collector **DaemonSet** enriches telemetry with Kubernetes metadata.
3. A dedicated observability-cluster OTel **Gateway** applies filtering, normalization, tail sampling, and batching.
4. **Loki, Tempo, and Mimir** store logs, traces, and metrics in S3; **Grafana** queries all three.
5. `observability-platform/` holds the reusable templates you would scale across 1000+ services.

## Architecture

![AWS Architecture Diagram](.github/assets/aws_architecture.png)

Lightweight collectors run next to workloads, centralized regional gateways own policy, and backend-specific exporters sit behind the gateway. Two EKS clusters in peered VPCs keep the workload and observability planes separate.

## What Actually Gets Deployed

| Component | Chart | Version | Pods | Notes |
|---|---|---|---|---|
| Loki | `grafana/loki` | 7.2.0 | 1 | SingleBinary, S3-backed |
| Tempo | `grafana/tempo` | 1.24.4 | 1 | Monolithic, S3-backed |
| Mimir | `grafana/mimir-distributed` | 6.1.0 | 8 | One replica per component, S3-backed |
| Grafana | `grafana/grafana` | 10.5.15 | 1 | Datasources + dashboard sidecar |
| OTel Gateway | `OpenTelemetryCollector` CR | contrib 0.156.0 | 2–10 | HPA on CPU |
| cert-manager | `jetstack/cert-manager` | v1.21.1 | 3 | Webhook TLS for the OTel Operator |
| OTel Operator | `open-telemetry/opentelemetry-operator` | 0.120.0 | 1 | |
| AWS LB Controller | `eks/aws-load-balancer-controller` | 3.4.3 | 1 | ALB for Grafana, NLB for the gateway |
| Karpenter | `oci://public.ecr.aws/karpenter` | 1.0.6 | 1 | Scales out when pods go Pending |

Every chart version is pinned. Helm values live in [`terraform/observability-cluster/helm-values/`](terraform/observability-cluster/helm-values/) rather than in Terraform `set` blocks, so they can be rendered and diffed before an apply.

## Repository Layout

```text
apps-workload-cluster-1/
  apps-src/
    golang-app/               # Go service, programmatic OTel SDK setup
    python-app/               # Python service, OTel Operator auto-instrumentation
  k8s-manifests/
    otel-collector-daemonset.yaml
    golang-app/               # Deployment, Service, ALB Ingress
    python-app/               # Deployment, Service, Instrumentation CR

observability-platform/
  01-app-onboarding/          # Onboarding contract, per-language values and CRs
  02-gateway-configuration/   # Tenant routing and tail-sampling policy examples
  03-dashboards-and-alerts/   # Golden-signal dashboards and a generator chart
  04-cluster-gitops-baseline/ # Argo CD app-of-apps and workload baselines
  k8s-manifests/              # Deployable gateway, NLB, Grafana ingress, dashboards

terraform/
  apps-workload-cluster-1/    # Workload EKS cluster, ECR, networking, Helm
  observability-cluster/      # Observability EKS cluster, S3, IAM, Helm
    helm-values/              # Loki / Tempo / Mimir / Grafana values templates
    cluster-storage/          # gp3 StorageClass (installed before any PVC)
    karpenter-provisioner/    # NodePool + EC2NodeClass
  main.tf                     # Both clusters plus VPC peering
```

## Prerequisites

* **AWS credentials** with Admin/PowerUser permissions (`aws configure`).
* **Tools**: `kubectl` 1.23+, `terraform` 1.5.0+, `helm` 3.x, `python3`.
* **Container images**: the GitHub Actions workflow pushes the Go and Python images to ECR. The ECR repositories are created by Terraform, so run `make k8s-create` before expecting the workflow to succeed.

## Deploying

```bash
make k8s-create        # Provision both EKS clusters, then install Helm charts
make k8s-context       # Configure kubeconfig contexts
make k8s-deploy-all    # Deploy gateway, collectors, and the demo apps
```

`make k8s-create` runs **two sequential Terraform applies** and this ordering is load-bearing:

* **Stage 1** provisions VPCs, EKS, IAM, and S3 using explicit `-target` flags.
* **Stage 2** runs a full apply with `deploy_observability_stack=true` to install the Helm releases.

Collapsing them into one apply makes the Helm provider resolve `module.eks.cluster_endpoint` at plan time and try to reach an API server that is not serving yet. Use `make k8s-create-infra` / `make k8s-create-helm` to re-run a single stage after a partial failure.

## Accessing Grafana

```bash
make k8s-dashboards    # port-forward to http://localhost:3000
make grafana-password  # print the chart-generated admin password (user: admin)
```

An internet-facing ALB is also provisioned by `observability-platform/k8s-manifests/grafana-ingress.yaml`:

```bash
kubectl --context observability-cluster get ingress grafana-ingress -n monitoring
```

To generate traffic through the demo services:

```bash
ALB=$(kubectl --context apps-workload-cluster-1 get ingress app-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
while true; do curl -s "http://$ALB/product" > /dev/null; sleep 1; done
```

## Verifying

```bash
make k8s-status        # pods on both clusters, plus anything not Running
make helm-lint         # render the pinned charts locally, no cluster needed
```

`make helm-lint` is worth running before any change to `helm-values/`. Helm ignores unknown value keys silently, so a mistyped path does not fail the install — it quietly leaves the chart default in place.

## Operational Notes

These are the non-obvious failure modes this setup has to work around. Each one installs cleanly and fails later, which is what makes them expensive.

**Unpinned charts drift across majors.** An unpinned `helm_release` re-resolves to the newest chart on every apply. Between two applies, `grafana/loki` grew memcached tiers and `mimir-distributed` adopted a Kafka-backed ingest path — enough to turn a working stack into an unschedulable one with no repo change in between.

**Loki's chart defaults do not fit a demo cluster.** `chunksCache` requests **9830Mi** of memory and `resultsCache` **1229Mi**. Neither can be scheduled on a t3-class node, so `helm_release.loki` blocks on `wait = true` until it times out. Both are disabled, along with the canary DaemonSet and the nginx gateway.

**Mimir 6.x defaults to Kafka ingest storage.** The chart hardcodes `ingest_storage.enabled: true` *and* `ingester.push_grpc_method_enabled: false`, because writes are expected to arrive through Kafka. Disabling Kafka without re-enabling the gRPC push method leaves the distributor unable to reach the ingester and every remote-write returns 500. Both settings are overridden together.

**Tempo's values are namespaced under `tempo:`.** There is no top-level `storage:` key. Setting `storage.trace.backend=s3` is accepted silently and leaves Tempo on `backend: local`, writing traces to ephemeral pod storage while the S3 bucket stays empty — a bug that only surfaces when a pod restarts.

**cert-manager must track the Kubernetes version.** v1.14 supports Kubernetes up to 1.29; on this cluster's 1.35 API server its webhook cannot serve, which blocks the OTel Operator install behind a CA injection that never completes.

**DaemonSet collectors need node-local traffic.** `k8sattributes` uses `filter.node_from_env_var` to cache only its own node's pods. Routing workloads through the collector's ClusterIP Service round-robins across nodes, so telemetry landing on another node's collector comes out with no `k8s.*` attributes at all. Workloads resolve `status.hostIP` through the Downward API instead, and the collector runs with `hostNetwork: true`.

**StorageClasses must exist before the PVCs.** Loki, Tempo, and Mimir all create claims. With `-parallelism=20` Terraform is free to start those releases before a StorageClass exists, so `gp3` is its own early Helm release that every stateful release depends on, and each PVC names it explicitly rather than relying on the default-class annotation (EKS ships its own default `gp2`).

**Declared is not the same as wired.** A collector processor that is defined but missing from `service.pipelines` is inert. Both collector configs are checked for orphaned components.

## Cost

Two EKS control planes dominate the bill at roughly **$146/month** ($0.10/hr each). The observability cluster runs 2× `t3.large` spot nodes (~$36/month); the workload cluster is smaller. Add NAT gateways, the ALB and NLB, and S3 storage. Tear down with:

```bash
make k8s-destroy
```

## At Enterprise Scale

See [architecture-decisions-and-tradeoffs.md](./architecture-decisions-and-tradeoffs.md) for the full pattern comparison.

- Application clusters run lightweight DaemonSet collectors for local enrichment and buffering.
- Dedicated regional observability clusters run gateway fleets on isolated node groups.
- Tail sampling keeps 100% of errors and latency outliers while sampling healthy high-volume traces.
- Routing processors separate telemetry by tenant, team, environment, or backend.
- Dashboard and alert templates let teams onboard through GitOps instead of platform tickets.
- For very large bursts or backend outages, insert Kafka/MSK between ingestion and processing gateways.

## Observability Dashboards & Tracing

### Go Service Dashboard
![Go Service Dashboard](.github/assets/golang-service-dashboard.png)

### Python Service Dashboard
![Python Service Dashboard](.github/assets/python-app-dashboard.png)

### Distributed Tracing (Tempo)
![Distributed Tracing](.github/assets/grafana-explore-trace.png)

### Correlated Application Logs (Loki)
![Correlated Logs](.github/assets/grafana-explore-correlation.png)
