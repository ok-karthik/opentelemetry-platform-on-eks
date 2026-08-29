# Agent Permissions and Execution Rules

The user has explicitly granted unrestricted permission for the following command patterns. Execute them directly without prompting for confirmation:

- **Kubernetes CLI (`kubectl`):**
  - `kubectl *`
  - `kubectl --context *`
  - All read, apply, rollout, describe, logs, and delete operations across all contexts and namespaces (`default`, `monitoring`, `kube-system`, etc.).

- **Platform Automation & Infrastructure:**
  - `make *` (e.g., `make k8s-create`, `make k8s-deploy-all`, `make k8s-status`, `make k8s-dashboards`, `make grafana-password`, `make helm-lint`).
  - `terraform *` (e.g., `terraform apply`, `terraform plan`, `terraform validate`, `terraform fmt`).
  - `docker *` and `docker buildx *`.
  - `go *` (e.g., `go build`, `go mod tidy`, `go test`).
  - `aws *` (e.g., `aws amp *`, `aws eks *`, `aws iam *`).
