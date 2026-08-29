# Argo CD App-of-Apps Pattern (EKS Managed Capabilities)

This directory demonstrates how a platform team exposes observability as a reusable GitOps product using **Amazon EKS Managed Capabilities for Argo CD (`control-plane-argocd`)**.

---

## 1. Amazon EKS Managed Capability for Argo CD

Rather than self-hosting 5–7 pods (Argo CD server, repo-server, application-controller, Redis HA, and Dex) on your worker nodes, this architecture leverages the **Amazon EKS Managed Capability for Argo CD (`control-plane-argocd`)**.

### Key Architectural Benefits:
* **Zero Worker Node Overhead:** The GitOps controller, caching layer (Redis), and web UI run in AWS-managed control plane infrastructure. Zero EC2 compute/RAM is consumed on your worker nodes.
* **Declarative Custom Resources:** Your cluster only contains standard Kubernetes CRDs (`Application`, `AppProject`).
* **Zero Maintenance Toil:** AWS handles automated high availability, CVE patching, state backups, and version upgrades.
* **IAM Identity Center Integration:** Seamless enterprise single sign-on (SSO) and cross-cluster deployment permissions via EKS Access Entries.

---

## 2. Directory Layout

- **`root-application.yaml`**: The parent Argo CD `Application` (App-of-Apps) that automatically discovers and synchronizes all child applications in `apps/`.
- **`appproject-platform.yaml`**: The `AppProject` restricting destination namespaces and permitted source repositories.
- **`apps/`**: Declarative child `Application` resources (e.g., `product-info-observability.yaml`) defining workload dashboard and alerting subscriptions.

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
   kubectl apply -f observability-platform/argocd/root-application.yaml
   ```
