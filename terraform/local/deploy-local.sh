#!/usr/bin/env bash
# ==============================================================================
# Deploy local portability profile (kind/k3d/orbstack + MinIO)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== [Local Profile] Checking Kubernetes Cluster ==="
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")

if [ -z "${CURRENT_CTX}" ]; then
  if command -v kind >/dev/null 2>&1; then
    echo "No active Kubernetes context found. Creating kind cluster 'otel-local'..."
    kind create cluster --name otel-local
    CURRENT_CTX="kind-otel-local"
  else
    echo "Error: No Kubernetes cluster detected and 'kind' is not installed." >&2
    exit 1
  fi
fi

echo "Using Kubernetes context: ${CURRENT_CTX}"

# Ensure gp3 StorageClass exists locally by aliasing to the cluster default provisioner
if ! kubectl get sc gp3 >/dev/null 2>&1; then
  DEFAULT_PROV=$(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].provisioner}' 2>/dev/null || echo "")
  if [ -z "${DEFAULT_PROV}" ]; then
    DEFAULT_PROV=$(kubectl get sc -o jsonpath='{.items[0].provisioner}' 2>/dev/null || echo "rancher.io/local-path")
  fi
  echo "Aliasing 'gp3' StorageClass to local provisioner: ${DEFAULT_PROV}"
  cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ${DEFAULT_PROV}
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF
fi

echo "=== [1/7] Preparing Namespaces ==="
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace default --dry-run=client -o yaml | kubectl apply -f -

echo "=== [2/7] Deploying MinIO S3 & Initializing Buckets ==="
kubectl apply -f "${SCRIPT_DIR}/minio.yaml"
echo "Waiting for MinIO bucket creation job to complete..."
kubectl wait --for=condition=complete job/minio-create-buckets -n observability --timeout=120s || true

echo "=== [3/7] Rendering Local Chart Values from Base Terraform Templates ==="
python3 "${SCRIPT_DIR}/render-values.py"

echo "=== [4/7] Updating Helm Repositories ==="
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update grafana open-telemetry jetstack >/dev/null 2>&1 || true

echo "=== [5/7] Deploying Prerequisites (cert-manager & OpenTelemetry Operator) ==="
if ! kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
  echo "Installing cert-manager (v1.21.1)..."
  helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.1 -n cert-manager --create-namespace \
    --set "crds.enabled=true" --wait --timeout=180s
fi

if ! kubectl get deployment opentelemetry-operator -n opentelemetry-operator-system >/dev/null 2>&1; then
  echo "Installing OpenTelemetry Operator (0.120.0)..."
  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator --version 0.120.0 -n opentelemetry-operator-system --create-namespace \
    --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib" \
    --wait --timeout=180s
fi

echo "=== [6/7] Deploying Observability Stack (Loki, Tempo, Mimir, Grafana) ==="
helm upgrade --install loki grafana/loki --version 7.2.0 -n observability \
  -f "${ROOT_DIR}/.local-render/loki.yaml" \
  -f "${SCRIPT_DIR}/overlays/loki-overlay.yaml" \
  --wait --timeout=300s || true

helm upgrade --install tempo grafana/tempo --version 1.24.4 -n observability \
  -f "${ROOT_DIR}/.local-render/tempo.yaml" \
  -f "${SCRIPT_DIR}/overlays/tempo-overlay.yaml" \
  --wait --timeout=300s || true

helm upgrade --install mimir grafana/mimir-distributed --version 6.1.0 -n observability \
  -f "${ROOT_DIR}/.local-render/mimir.yaml" \
  -f "${SCRIPT_DIR}/overlays/mimir-overlay.yaml" \
  --wait --timeout=300s || true

helm upgrade --install grafana grafana/grafana --version 10.5.15 -n observability \
  -f "${ROOT_DIR}/.local-render/grafana.yaml" \
  -f "${SCRIPT_DIR}/overlays/grafana-overlay.yaml" \
  --wait --timeout=300s || true

echo "=== [7/7] Applying Observability Runtime Manifests & Workloads ==="
kubectl apply -f "${ROOT_DIR}/observability-runtime/sre-agent-rbac.yaml"
kubectl apply -f "${ROOT_DIR}/observability-runtime/mimir-ruler-rules-configmap.yaml"
kubectl apply -f "${ROOT_DIR}/observability-runtime/alert-sink.yaml"
kubectl apply -f "${ROOT_DIR}/observability-runtime/grafana-dashboards/"
kubectl apply -f "${ROOT_DIR}/observability-runtime/gateways/"
kubectl apply -f "${ROOT_DIR}/workloads/otel-collector-daemonset.yaml"
kubectl apply -f "${ROOT_DIR}/workloads/python-app/otel-instrumentation-python.yaml"
kubectl apply -f "${ROOT_DIR}/workloads/golang-app/golang-product-service.yaml"
kubectl apply -f "${ROOT_DIR}/workloads/python-app/python-product-info-service.yaml"

echo ""
echo "=== Local Observability Platform Deployed Successfully! ==="
echo "Access Grafana: kubectl port-forward -n observability svc/grafana 3000:80"
echo "Access MinIO:   kubectl port-forward -n observability svc/minio 9001:9001"
