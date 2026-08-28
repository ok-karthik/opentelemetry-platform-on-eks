# CLAUDE.md

The full project mental model, repository structure, and working rules for this
repository live in **[.agents/AGENTS.md](./.agents/AGENTS.md)**. Read that file
first — it is the single source of truth and this file intentionally does not
duplicate it.

## Quick orientation

Two EKS clusters in peered VPCs. Applications emit OTLP to a node-local
Collector DaemonSet, which forwards to a central Gateway on a dedicated
observability cluster, which exports to Loki, Tempo, and Mimir backed by S3,
with Grafana on top.

```text
app pod -> DaemonSet collector (workload cluster)
        -> OTel Gateway (observability cluster)
        -> Loki / Tempo / Mimir -> Grafana
```

| Where | What |
|---|---|
| `workloads/` | Demo Go + Python services, their manifests, the DaemonSet collector |
| `observability-platform/` | Platform-owned templates: onboarding, gateway policy, dashboards, GitOps |
| `terraform/` | Both clusters. Backend Helm values in `observability-cluster/helm-values/` |
| `.agents/AGENTS.md` | Architecture, conventions, and the chart-specific traps |

## Before you change anything

- **Helm values**: run `make helm-lint`. Helm ignores unknown value keys
  silently, so a mistyped path leaves the chart default in place instead of
  failing. Rendering and diffing is the only reliable check.
- **Terraform**: run `terraform fmt` on modified `.tf` files, then
  `terraform validate` from `terraform/`.
- **Collector configs**: verify every declared receiver, processor, connector,
  and exporter actually appears in `service.pipelines`. A declared-but-unwired
  component is inert and fails silently.
- **Chart versions**: pin them. They live in the `local.chart_versions` map at
  the top of each `helm-charts.tf`.
- **Go service**: `cd workloads/apps-src/golang-app && go build ./...`

## Common commands

```bash
make k8s-create        # two-stage Terraform apply (infra, then Helm)
make k8s-context       # kubeconfig contexts for both clusters
make k8s-deploy-all    # gateway, collectors, demo apps
make k8s-status        # pods on both clusters, plus anything not Running
make k8s-dashboards    # port-forward Grafana to localhost:3000
make grafana-password  # generated admin password
make helm-lint         # render the pinned charts locally
make k8s-destroy       # tear everything down
```

## Things that are easy to get wrong here

Each of these installs cleanly and fails later. They are covered in detail in
[.agents/AGENTS.md](./.agents/AGENTS.md); the short version:

- Tempo values are namespaced under `tempo:`. A top-level `storage:` key is
  accepted and ignored, leaving traces on ephemeral local disk.
- Mimir's chart defaults to Kafka ingest storage and hardcodes
  `ingester.push_grpc_method_enabled: false`. Disabling Kafka without flipping
  that back makes every remote-write return 500.
- Loki's `chunksCache` requests ~9.6 GiB by default and cannot be scheduled on a
  demo node.
- cert-manager's version has to track the cluster's Kubernetes version.
- Workloads must reach their **node-local** collector via `status.hostIP`; the
  ClusterIP Service silently loses `k8s.*` enrichment.
- The OTel Operator names a collector's Service `<collector-name>-collector`.

## Scope rules

- Preserve user changes; do not revert unrelated working-tree edits.
- Keep the distinction between workload-cluster and observability-platform
  configs intact.
- Update the docs when changing architecture, ports, service names, cluster
  names, chart versions, or onboarding flows.
