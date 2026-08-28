# Workload Cluster Baseline

These templates are consumed by workload clusters.

The workload cluster should not hardcode vendor backends or central gateway DNS names in every collector manifest. Instead, expose one stable in-cluster name and point the node collector to that name.

Recommended pattern:

```text
workload collector -> otel-gateway-regional.monitoring.svc.cluster.local -> regional gateway NLB
```

In a real platform, the ExternalName target is rendered from Helm values, ExternalDNS, or a cluster bootstrap ConfigMap.
