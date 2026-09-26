#!/usr/bin/env bash
# ==============================================================================
# Teardown local portability profile
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== Tearing Down Local Observability Stack ==="

helm uninstall grafana -n observability 2>/dev/null || true
helm uninstall mimir -n observability 2>/dev/null || true
helm uninstall tempo -n observability 2>/dev/null || true
helm uninstall loki -n observability 2>/dev/null || true

kubectl delete -f "${ROOT_DIR}/workloads/golang-app/golang-product-service.yaml" 2>/dev/null || true
kubectl delete -f "${ROOT_DIR}/workloads/python-app/python-product-info-service.yaml" 2>/dev/null || true
kubectl delete -f "${ROOT_DIR}/workloads/otel-collector-daemonset.yaml" 2>/dev/null || true
kubectl delete -f "${ROOT_DIR}/observability-runtime/gateways/" 2>/dev/null || true
kubectl delete -f "${SCRIPT_DIR}/minio.yaml" 2>/dev/null || true
kubectl delete -f "${ROOT_DIR}/observability-runtime/sre-agent-rbac.yaml" 2>/dev/null || true
kubectl delete -f "${ROOT_DIR}/observability-runtime/mimir-ruler-rules-configmap.yaml" 2>/dev/null || true
kubectl delete -f "${ROOT_DIR}/observability-runtime/alert-sink.yaml" 2>/dev/null || true
kubectl delete namespace observability 2>/dev/null || true

echo "Uninstalling OpenTelemetry Operator and cert-manager..."
helm uninstall opentelemetry-operator -n opentelemetry-operator-system 2>/dev/null || true
helm uninstall cert-manager -n cert-manager 2>/dev/null || true
kubectl delete namespace opentelemetry-operator-system 2>/dev/null || true
kubectl delete namespace cert-manager 2>/dev/null || true

if kubectl config current-context | grep -q "kind-otel-local"; then
  echo "Deleting kind cluster otel-local..."
  kind delete cluster --name otel-local || true
fi

echo "Local teardown complete."
