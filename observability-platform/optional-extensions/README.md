# Optional Enterprise Log Analytics Extensions

This directory contains optional manifests for the **Kafka $\rightarrow$ Logstash $\rightarrow$ OpenSearch** log pipeline.

## Overview
By default, the platform uses a **Loki-first architecture** where all logs are shipped directly over native OTLP (`otlphttp/loki`) into S3 storage for maximum cost efficiency and sub-second trace-to-log correlation.

These manifests provide a pre-configured template for organizations requiring:
1. **Kafka Telemetry Buffer:** Absorbing extreme burst traffic (>25,000 events/sec) or decoupling backend storage maintenance.
2. **OpenSearch Index Bootstrap:** Pre-configuring OpenSearch with an explicit field mapping template and 7-day ISM (Index State Management) rollover policy.

## How to Enable
1. Enable OpenSearch, Logstash, and OpenSearch Dashboards in `terraform/modules/observability-stack/helm-charts.tf`.
2. Apply `kafka-stub.yaml` to provide the in-cluster Kafka broker.
3. Apply `opensearch-index-bootstrap-job.yaml` to initialize the index templates and ISM policies.
4. Enable the `kafka/logs` exporter in `observability-platform/k8s-manifests/otel-collector-gateway.yaml`.
