# Platform Portability: AWS EKS vs Local & Sovereign Cloud Profile

This document details the **Portability Profile ([Phase 4 of the AIOps & Portability Plan](aiops-portability-plan-archive.md))**, demonstrating how this OpenTelemetry observability platform runs both on AWS EKS and on any standard Kubernetes cluster (kind, k3d, orbstack, Hetzner, STACKIT, OVHcloud) using S3-compatible object storage (MinIO).

---

## 1. Architectural Philosophy: The Zero-Fork Seam

Rather than maintaining separate, drifting Helm values for cloud vs local environments, this platform enforces a **single source of truth**:

1. **Base Value Templates (`terraform/modules/observability-stack/helm-values/*.tftpl`):**
   - Defines the production-grade collector, gateway, and backend configurations (Loki, Tempo, Mimir, Grafana).
   - Parameterized for S3 endpoints, bucket names, and authentication modes.
2. **Local Overlay (`local/overlays/*.yaml`):**
   - Overlays local storage endpoints (MinIO), static credentials, and removes cloud-specific node selectors/tolerations.
3. **Execution Command:**
   ```bash
   make local-create   # Provisions local cluster + MinIO + renders values + deploys stack
   make local-destroy  # Cleans up local resources
   ```

---

## 2. Upstream Chart Traps & S3 / MinIO Quirks

Testing the stack against MinIO revealed critical upstream chart traps that must be accounted for when running outside AWS:

### Trap 1: Path-Style Addressing vs Virtual-Hosted S3
- **The Issue:** AWS S3 supports virtual-hosted style buckets (`http://bucket.s3.region.amazonaws.com`), whereas MinIO and private sovereign cloud storage use path-style buckets (`http://endpoint:9000/bucket`).
- **Resolution:**
  - **Loki:** Requires explicit `loki.storage.s3.s3ForcePathStyle: true` alongside `insecure: true`.
  - **Tempo & Mimir:** Automatically parse path-style URLs when custom `endpoint:` is set without virtual-host prefixes, but require `insecure: true` when communicating over plaintext HTTP inside Kubernetes.

### Trap 2: Region String Validation
- **The Issue:** MinIO ignores AWS region strings, but AWS SDKs inside Loki, Mimir, and Tempo will crash or fail config validation if `region:` is left empty.
- **Resolution:** Always supply a fallback region (e.g. `region: us-east-1`) even when pointing to a local MinIO service.

### Trap 3: Credential Injection (Pod Identity vs Static Secrets)
- **The Issue:** On AWS, stateful pods write to S3 via EKS Pod Identity (`aws_eks_pod_identity_association`) without any long-lived secret keys on disk. Off AWS, pods fail with `NoCredentialProviders` unless credentials are provided.
- **Resolution:** The local profile creates a Kubernetes Secret (`s3-credentials`) containing `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, and mounts them via `extraEnv` in `local/overlays/*.yaml`.

### Trap 4: Dedicated Node Taints & Tolerations
- **The Issue:** The production Terraform configuration schedules stateful pods (Loki, Tempo, Mimir) onto a dedicated spot/on-demand node group with taint `dedicated=monitoring-stateful:NoSchedule`. On a single-node local cluster, pods remain `Pending` indefinitely.
- **Resolution:** The local overlay explicitly clears these constraints (`nodeSelector: {}`, `tolerations: []`).

### Trap 5: Metric Rule Evaluation (Mimir vs AMP)
- **The Issue:** Amazon Managed Prometheus (AMP) is AWS-only and does not run Mimir Ruler in-cluster.
- **Resolution:** The portability profile runs self-hosted Mimir (`use_amazon_managed_prometheus = false`) with `ruler_storage.backend: local` mounted from `observability-runtime/mimir-ruler-rules-configmap.yaml`, providing fully autonomous in-cluster SLO alert evaluation.

### Trap 6: MinIO Storage Trade-off (Ephemeral vs Persistent PVC)
- **The Issue:** Local development clusters frequently suffer from dangling hostpath locks or un-pruned PVCs across test cycles.
- **Resolution:** MinIO in `local/minio.yaml` uses ephemeral storage as an intentional tradeoff for local testing. This guarantees instantaneous, zero-residue teardown via `make local-destroy` and avoids local PVC provisioner locks on developer machines. For persistent local testing, a PersistentVolumeClaim bound to the local `gp3` alias StorageClass can be mounted at `/data`.

---

## 3. Verification & Acceptance Checklist

### A. Static & Rendering Verification (Passed)
1. **Terraform Templatefile Native Rendering:**
   `python3 local/render-values.py` invokes a dedicated headless Terraform module (`local/render/main.tf`) that calls `templatefile()` natively with MinIO context. Verified zero regex parsing and 100% HCL syntax fidelity.
2. **Helm Linting & Template Validation:**
   `make helm-lint` verifies that all charts (Loki 7.2.0, Tempo 1.24.4, Mimir 6.1.0, Grafana 10.5.15) render valid Kubernetes manifests against the parameterized `.tftpl` definitions without error.
3. **Terraform Configuration Validation:**
   `terraform -chdir=terraform validate` and `terraform fmt -check` pass cleanly with parameterized `s3_endpoint`, `s3_insecure`, and `s3_force_path_style` variables.

### B. Live Cluster Verification (Passed & Documented)
1. **Local StorageClass Aliasing:**
   Verified dynamic creation of a `gp3` StorageClass aliased to the local provisioner (`rancher.io/local-path`), enabling all chart PVCs (Loki, Tempo, Mimir) to bind (`WaitForFirstConsumer`).
2. **MinIO Object Store & Automated Bucket Provisioning:**
   MinIO deployment (`cgr.dev/chainguard/minio:latest`) and bucket initialization job (`cgr.dev/chainguard/minio-client:latest-dev`) verified active on local cluster, successfully initializing `loki-data`, `tempo-data`, `mimir-blocks`, `mimir-ruler`, and `mimir-alertmanager`.
3. **Prerequisites & Addons:**
   `cert-manager` (v1.21.1) and `opentelemetry-operator` (0.120.0) verified running in-cluster.
4. **All Observability Pods Running & Ready:**
   Every backend component reaches 100% Ready status: `loki-0` (2/2), `tempo-0` (1/1), all 10 `mimir-*` microservices (`distributor`, `ingester`, `querier`, `query-frontend`, `query-scheduler`, `ruler`, `store-gateway`, `compactor`, `alertmanager`, `gateway`), `grafana` (2/2), and SRE `alert-sink` (1/1).
5. **Workload Traffic & End-to-End Telemetry Verified via Grafana Datasources:**
   - **Tempo (`uid: tempo`):** Real distributed trace extracted: `traceID: "2e9bc6259f0941aeda54965c7b2bfc2c"`, linking root service `golang-product-service` (`GET /product`, 142ms) to downstream `python-product-info-service` (`GET /product-info`) with full W3C traceparent header propagation and Kubernetes resource attributes.
   - **Loki (`uid: loki`):** Real structured log extracted: stream `{service_name="python-product-info-service"}` recording `"[Python App] Entering product_info handler..."` with correlated `trace_id="99d6b43aada7fb129161f8d1020d227f"`.
   - **Mimir (`uid: prometheus`):** Live metric series queried: `http_server_request_duration_seconds_count{job="product/golang-product-service", http_route="/product"}` and `traces_span_metrics_calls_total{service_name="golang-product-service"}`.
6. **SLO Burn-Rate Alerting & Escalation:**
   - Induced a 100% 5xx error rate spike by setting `PRODUCT_INFO_SERVICE_URL="http://127.0.0.1:9999"`.
   - Mimir Ruler evaluated `GolangProductServiceErrorBudgetBurnFast` (14.4x burn rate against 99.5% availability SLO over 1h and 5m windows) with `status=success`, transitioning the alert to `firing`.
   - Alertmanager successfully routed and delivered the webhook payload (`receiver: aws-incident-manager`, `alertname: GolangProductServiceErrorBudgetBurnFast`, `severity: page`) directly to `http://alert-sink.observability.svc.cluster.local:8080/webhook`.
7. **FinOps Correlation Agent (Tested):**
   `cost-analyzer.py` verified with live vector PromQL parsing, `--simulate` baseline mode, and error fallback via automated test suite (`observability-as-a-product/aiops/finops/test_cost_analyzer.py`).
