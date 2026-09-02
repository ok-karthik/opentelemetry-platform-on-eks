# ==============================================================================
# Observability Platform Helm Releases
# Loki, Tempo, Mimir, Grafana, and optional OpenSearch stack
# ==============================================================================

locals {
  chart_versions = {
    loki                  = "7.2.0"
    tempo                 = "1.24.4"
    mimir                 = "6.1.0"
    grafana               = "10.5.15"
    opensearch            = "3.8.0"
    opensearch_dashboards = "3.8.0"
    logstash              = "8.5.1"
  }
}

# ------------------------------------------------------------------------------
# 1. Loki — 1 pod
# ------------------------------------------------------------------------------
resource "helm_release" "loki" {
  count = var.deploy_observability_stack ? 1 : 0

  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = local.chart_versions.loki
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 600

  values = [
    templatefile("${path.module}/helm-values/loki.yaml.tftpl", {
      loki_bucket = aws_s3_bucket.loki_data.bucket
      aws_region  = var.aws_region
    })
  ]

  depends_on = [
    aws_eks_pod_identity_association.loki,
  ]
}

# ------------------------------------------------------------------------------
# 2. Tempo — 1 pod
# ------------------------------------------------------------------------------
resource "helm_release" "tempo" {
  count = var.deploy_observability_stack ? 1 : 0

  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo"
  version          = local.chart_versions.tempo
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 600

  values = [
    templatefile("${path.module}/helm-values/tempo.yaml.tftpl", {
      tempo_bucket = aws_s3_bucket.tempo_data.bucket
      aws_region   = var.aws_region
    })
  ]

  depends_on = [
    aws_eks_pod_identity_association.tempo,
  ]
}

# ------------------------------------------------------------------------------
# 3. Mimir — Optional self-hosted fallback (disabled when use_amazon_managed_prometheus=true)
# ------------------------------------------------------------------------------
resource "helm_release" "mimir" {
  count = (var.deploy_observability_stack && !var.use_amazon_managed_prometheus) ? 1 : 0

  name             = "mimir"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "mimir-distributed"
  version          = local.chart_versions.mimir
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 900

  values = [
    templatefile("${path.module}/helm-values/mimir.yaml.tftpl", {
      mimir_blocks_bucket       = var.use_amazon_managed_prometheus ? "" : aws_s3_bucket.mimir_blocks[0].bucket
      mimir_ruler_bucket        = var.use_amazon_managed_prometheus ? "" : aws_s3_bucket.mimir_ruler[0].bucket
      mimir_alertmanager_bucket = var.use_amazon_managed_prometheus ? "" : aws_s3_bucket.mimir_alertmanager[0].bucket
      aws_region                = var.aws_region
    })
  ]
}

# ------------------------------------------------------------------------------
# 4. Grafana — 1 pod
# ------------------------------------------------------------------------------
resource "helm_release" "grafana" {
  count = (var.deploy_observability_stack && !var.use_amazon_managed_grafana) ? 1 : 0

  name             = "grafana"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "grafana"
  version          = local.chart_versions.grafana
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 300

  values = [
    templatefile("${path.module}/helm-values/grafana.yaml.tftpl", {
      use_amp                = var.use_amazon_managed_prometheus
      amp_workspace_endpoint = var.use_amazon_managed_prometheus ? aws_prometheus_workspace.amp[0].prometheus_endpoint : ""
      aws_region             = var.aws_region
    })
  ]

  depends_on = [
    helm_release.loki,
    helm_release.tempo,
  ]
}

# ==============================================================================
# Optional Enterprise Log Analytics Path — OpenSearch, Dashboards, Logstash
# ==============================================================================

# ------------------------------------------------------------------------------
# 5. OpenSearch — 1 pod, security plugin disabled (optional enterprise path)
# ------------------------------------------------------------------------------
resource "helm_release" "opensearch" {
  count = var.deploy_opensearch_stack ? 1 : 0

  name             = "opensearch"
  repository       = "https://opensearch-project.github.io/helm-charts/"
  chart            = "opensearch"
  version          = local.chart_versions.opensearch
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 600

  values = [
    templatefile("${path.module}/helm-values/opensearch.yaml.tftpl", {})
  ]
}

# ------------------------------------------------------------------------------
# 6. OpenSearch Dashboards — 1 pod (optional enterprise path)
# ------------------------------------------------------------------------------
resource "helm_release" "opensearch_dashboards" {
  count = var.deploy_opensearch_stack ? 1 : 0

  name       = "opensearch-dashboards"
  repository = "https://opensearch-project.github.io/helm-charts/"
  chart      = "opensearch-dashboards"
  version    = local.chart_versions.opensearch_dashboards
  namespace  = "monitoring"

  wait    = true
  timeout = 300

  values = [
    templatefile("${path.module}/helm-values/opensearch-dashboards.yaml.tftpl", {})
  ]

  depends_on = [
    helm_release.opensearch,
  ]
}

# ------------------------------------------------------------------------------
# 7. Logstash — 1 pod, Kafka -> OpenSearch (optional enterprise path)
# ------------------------------------------------------------------------------
resource "helm_release" "logstash" {
  count = var.deploy_opensearch_stack ? 1 : 0

  name       = "logstash"
  repository = "https://helm.elastic.co"
  chart      = "logstash"
  version    = local.chart_versions.logstash
  namespace  = "monitoring"

  wait    = true
  timeout = 300

  values = [
    templatefile("${path.module}/helm-values/logstash.yaml.tftpl", {})
  ]

  depends_on = [
    helm_release.opensearch,
  ]
}
