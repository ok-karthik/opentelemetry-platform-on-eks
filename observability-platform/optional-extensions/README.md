# Optional Enterprise Log Analytics Extensions

This directory contains optional manifests for the **Kafka $\rightarrow$ Logstash $\rightarrow$ OpenSearch** log pipeline.

## Overview
By default, the platform uses a **Loki-first architecture** where all logs are shipped directly over native OTLP (`otlphttp/loki`) into S3 storage for maximum cost efficiency and sub-second trace-to-log correlation.

These manifests provide pre-configured templates for organizations requiring:
1. **Kafka Telemetry Buffer (`kafka-stub.yaml`):** Absorbing extreme burst traffic (>25,000 events/sec) or decoupling backend storage maintenance using dedicated EBS `gp3` storage.
2. **OpenSearch Index Bootstrap (`opensearch-index-bootstrap-job.yaml`):** Pre-configuring OpenSearch with an explicit field mapping template and 7-day ISM (Index State Management) rollover policy.
3. **KEDA Ingestion Rate Autoscaler (`keda-otel-autoscaler.yaml`):** Autoscaling OTel Tier 2 Routers instantaneously based on wire spans/sec rather than lagging CPU utilization.

## How to Enable
1. Enable OpenSearch, Logstash, and OpenSearch Dashboards in `terraform/modules/observability-stack/helm-charts.tf`.
2. Apply `kafka-stub.yaml` to provide the in-cluster Kafka broker.
3. Apply `opensearch-index-bootstrap-job.yaml` to initialize the index templates and ISM policies.
4. Enable the `kafka/logs` exporter in `observability-platform/otel-collector-gateway.yaml`.
5. Apply `keda-otel-autoscaler.yaml` to autoscale ingress routers on traffic volume.
