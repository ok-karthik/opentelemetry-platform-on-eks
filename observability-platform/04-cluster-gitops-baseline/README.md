# Cluster GitOps & Baseline

This directory demonstrates how a platform team exposes observability as a reusable GitOps product and how workload clusters consume it securely using **Amazon EKS Managed Capabilities**.

---

## 1. Amazon EKS Managed Capability for Argo CD

Rather than self-hosting 5–7 pods (Argo CD server, repo-server, application-controller, Redis HA, and Dex) on your worker nodes, this architecture leverages the **Amazon EKS Managed Capability for Argo CD (`control-plane-argocd`)**.

### Key Architectural Benefits:
* **Zero Worker Node Overhead:** The GitOps controller, caching layer (Redis), and web UI run in AWS-managed control plane infrastructure. Zero EC2 compute/RAM is consumed on your worker nodes.
* **Declarative Custom Resources:** Your cluster only contains standard Kubernetes CRDs (`Application`, `AppProject`).
* **Zero Maintenance Toil:** AWS handles automated high availability, CVE patching, state backups, and version upgrades.
* **IAM Identity Center Integration:** Seamless enterprise single sign-on (SSO) and cross-cluster deployment permissions via EKS Access Entries.

---

## 2. Contents

- **`gitops-app-of-apps/`**: Declarative Argo CD Application manifests leveraging the App-of-Apps pattern.
  - `root-application.yaml`: The parent application that syncs and orchestrates all child platform applications.
  - `apps/`: Child applications deploying workload instrumentation, golden signal dashboards, and regional routing.
- **`workload-cluster-baseline/`**: Standard Kubernetes baseline templates that provide stable internal DNS aliases for cross-cluster OTLP telemetry forwarding.

---

## 3. GitOps App-of-Apps Flow

```text
App Repo Values (GitHub)
  -> EKS Managed Argo CD Capability (Control Plane)
  -> Renders Platform Observability Charts
  -> Deploys Instrumentation, Gateways, Dashboards & Alert Rules across Clusters
```

### How to Enable via AWS Console / CLI:
1. Navigate to **EKS Console > Clusters > [Cluster Name] > Capabilities**.
2. Click **Create capabilities** and select **Argo CD** (`control-plane-argocd`).
3. Apply the root application:
   ```bash
   kubectl apply -f observability-platform/04-cluster-gitops-baseline/gitops-app-of-apps/root-application.yaml
   ```

---

## 4. Workload Cluster Baseline

Workload clusters never hardcode private AWS NLB DNS hostnames or vendor backend endpoints. Instead, they expose a single stable in-cluster `ExternalName` alias:

```text
Workload OTel Collector DaemonSet
  -> otel-gateway-regional.monitoring.svc.cluster.local
  -> AWS Network Load Balancer (NLB) (Instance Target Type)
  -> Central Observability Gateway Fleet (Tier 1 Routers -> Tier 2 Processors)
```
