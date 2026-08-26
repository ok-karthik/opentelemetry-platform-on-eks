
# ==============================================================================
# Helm Releases — Observability Cluster
#
# The four LGTM components are deployed from their individual official charts.
# Loki and Tempo run monolithic (1 pod each); Mimir runs the distributed chart
# scaled to a single replica per component. Values live in helm-values/ rather
# than in `set` blocks so they can be linted and rendered with `helm template`
# before an apply — see the README for the verification command.
#
# EVERY chart version is pinned. An unpinned `helm_release` silently upgrades
# across chart majors on the next `terraform apply`, which is how the previously
# working stack drifted into a broken one (Loki gained multi-GB memcached tiers
# and Mimir gained a bundled Kafka).
#
# Install dependency order:
#   cert-manager      ->  otel-operator            (webhook TLS)
#   aws-lb-controller                              (Pod Identity must exist first)
#   cluster-storage   ->  loki / tempo / mimir     (PVCs need the gp3 class)
#   karpenter         ->  karpenter-provisioner
# ==============================================================================

locals {
  # Chart versions — bump deliberately, then re-render helm-values/ to confirm
  # no value paths were renamed by the new chart.
  chart_versions = {
    cert_manager          = "v1.21.1"
    otel_operator         = "0.120.0"
    aws_lb_controller     = "3.4.3"
    loki                  = "7.2.0"
    tempo                 = "1.24.4"
    mimir                 = "6.1.0"
    grafana               = "10.5.15"
    karpenter             = "1.0.6"
    opensearch            = "3.8.0"
    opensearch_dashboards = "3.8.0"
    logstash              = "8.5.1"
  }
}

# ------------------------------------------------------------------------------
# 1. cert-manager
#
# The version must track the cluster's Kubernetes version. cert-manager v1.14
# only supports up to Kubernetes 1.29 — running it against this cluster's 1.35
# API server leaves the webhook unable to serve, which in turn blocks the
# OpenTelemetry Operator install behind a CA injection that never completes.
# ------------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = local.chart_versions.cert_manager
  namespace        = "cert-manager"
  create_namespace = true

  wait          = true
  atomic        = true
  wait_for_jobs = true
  timeout       = 600

  set {
    name  = "crds.enabled"
    value = "true"
  }

  set {
    name  = "resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "resources.requests.memory"
    value = "32Mi"
  }
  set {
    name  = "webhook.resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "webhook.resources.requests.memory"
    value = "32Mi"
  }
  set {
    name  = "cainjector.resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "cainjector.resources.requests.memory"
    value = "32Mi"
  }

  depends_on = [module.eks]
}

# ------------------------------------------------------------------------------
# 2. OpenTelemetry Operator
# ------------------------------------------------------------------------------
resource "helm_release" "otel_operator" {
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  version          = local.chart_versions.otel_operator
  namespace        = "opentelemetry-operator-system"
  create_namespace = true

  wait    = true
  atomic  = true
  timeout = 300

  set {
    name  = "manager.collectorImage.repository"
    value = "otel/opentelemetry-collector-contrib"
  }
  set {
    name  = "manager.resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "manager.resources.requests.memory"
    value = "64Mi"
  }

  depends_on = [helm_release.cert_manager, module.eks]
}

# ------------------------------------------------------------------------------
# 3. AWS Load Balancer Controller
# ------------------------------------------------------------------------------
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = local.chart_versions.aws_lb_controller
  namespace  = "kube-system"

  wait    = true
  atomic  = true
  timeout = 300

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "vpcId"
    value = aws_vpc.main.id
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "replicaCount"
    value = "1"
  }
  set {
    name  = "resources.requests.cpu"
    value = "25m"
  }
  set {
    name  = "resources.requests.memory"
    value = "64Mi"
  }

  depends_on = [helm_release.cert_manager, module.eks, aws_eks_pod_identity_association.aws_lb_controller]
}

# 3.1 AWS LB Controller — IAM (fetched from main branch to include DescribeListenerAttributes)
data "http" "aws_lb_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "aws_lb_controller" {
  name        = "${var.cluster_name}-aws-lb-controller-policy"
  path        = "/"
  description = "IAM policy for the AWS Load Balancer Controller in EKS"
  policy      = data.http.aws_lb_controller_iam_policy.response_body
}

resource "aws_iam_role" "aws_lb_controller" {
  name = "${var.cluster_name}-aws-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aws_lb_controller" {
  policy_arn = aws_iam_policy.aws_lb_controller.arn
  role       = aws_iam_role.aws_lb_controller.name
}

resource "aws_eks_pod_identity_association" "aws_lb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_lb_controller.arn
}

# ------------------------------------------------------------------------------
# 4. Cluster storage baseline (gp3 StorageClass)
#    Must exist before any chart that creates a PersistentVolumeClaim.
# ------------------------------------------------------------------------------
resource "helm_release" "cluster_storage" {
  name      = "cluster-storage"
  chart     = "${path.module}/cluster-storage"
  namespace = "kube-system"

  wait    = true
  timeout = 120

  depends_on = [module.eks]
}

# ==============================================================================
# Observability Backends
#
# `wait = true` without `atomic = true`: an atomic rollback tears the pods down
# on failure, which destroys the evidence needed to diagnose why an install did
# not converge.
# ==============================================================================

# ------------------------------------------------------------------------------
# 5. Loki — 1 pod
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
    module.eks,
    helm_release.cluster_storage,
    aws_eks_pod_identity_association.loki,
  ]
}

# ------------------------------------------------------------------------------
# 6. Tempo — 1 pod
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
    module.eks,
    helm_release.cluster_storage,
    aws_eks_pod_identity_association.tempo,
  ]
}

# ------------------------------------------------------------------------------
# 7. Mimir — 8 pods (one per component)
# ------------------------------------------------------------------------------
resource "helm_release" "mimir" {
  count = var.deploy_observability_stack ? 1 : 0

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
      mimir_blocks_bucket       = aws_s3_bucket.mimir_blocks.bucket
      mimir_ruler_bucket        = aws_s3_bucket.mimir_ruler.bucket
      mimir_alertmanager_bucket = aws_s3_bucket.mimir_alertmanager.bucket
      aws_region                = var.aws_region
    })
  ]

  depends_on = [
    module.eks,
    helm_release.cluster_storage,
    aws_eks_pod_identity_association.mimir,
  ]
}

# ------------------------------------------------------------------------------
# 8. Grafana — 1 pod
# ------------------------------------------------------------------------------
resource "helm_release" "grafana" {
  count = var.deploy_observability_stack ? 1 : 0

  name             = "grafana"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "grafana"
  version          = local.chart_versions.grafana
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 300

  # templatefile (not file) so the `$${...}` escapes in the datasource
  # definitions collapse to the literal `${...}` Grafana expects.
  values = [
    templatefile("${path.module}/helm-values/grafana.yaml.tftpl", {})
  ]

  depends_on = [
    module.eks,
    helm_release.loki,
    helm_release.mimir,
    helm_release.tempo,
  ]
}

# ==============================================================================
# Optional Enterprise Log Analytics Path — OpenSearch, Dashboards, Logstash
#
# Disabled/Commented by default in favor of lightweight, production-grade Loki.
# To re-enable full-text indexing, aggregations, or SIEM analytics, uncomment
# the releases below.
# ==============================================================================

# # ------------------------------------------------------------------------------
# # 9. OpenSearch — 1 pod, security plugin disabled
# # ------------------------------------------------------------------------------
# resource "helm_release" "opensearch" {
#   count = var.deploy_observability_stack ? 1 : 0
# 
#   name             = "opensearch"
#   repository       = "https://opensearch-project.github.io/helm-charts/"
#   chart            = "opensearch"
#   version          = local.chart_versions.opensearch
#   namespace        = "monitoring"
#   create_namespace = true
# 
#   wait    = true
#   timeout = 600
# 
#   values = [
#     templatefile("${path.module}/helm-values/opensearch.yaml.tftpl", {})
#   ]
# 
#   depends_on = [
#     module.eks,
#     helm_release.cluster_storage,
#   ]
# }
# 
# # ------------------------------------------------------------------------------
# # 10. OpenSearch Dashboards — 1 pod
# # ------------------------------------------------------------------------------
# resource "helm_release" "opensearch_dashboards" {
#   count = var.deploy_observability_stack ? 1 : 0
# 
#   name       = "opensearch-dashboards"
#   repository = "https://opensearch-project.github.io/helm-charts/"
#   chart      = "opensearch-dashboards"
#   version    = local.chart_versions.opensearch_dashboards
#   namespace  = "monitoring"
# 
#   wait    = true
#   timeout = 300
# 
#   values = [
#     templatefile("${path.module}/helm-values/opensearch-dashboards.yaml.tftpl", {})
#   ]
# 
#   depends_on = [
#     module.eks,
#     helm_release.opensearch,
#   ]
# }
# 
# # ------------------------------------------------------------------------------
# # 11. Logstash — 1 pod, Kafka -> OpenSearch
# # ------------------------------------------------------------------------------
# resource "helm_release" "logstash" {
#   count = var.deploy_observability_stack ? 1 : 0
# 
#   name       = "logstash"
#   repository = "https://helm.elastic.co"
#   chart      = "logstash"
#   version    = local.chart_versions.logstash
#   namespace  = "monitoring"
# 
#   wait    = true
#   timeout = 300
# 
#   values = [
#     templatefile("${path.module}/helm-values/logstash.yaml.tftpl", {})
#   ]
# 
#   depends_on = [
#     module.eks,
#     helm_release.opensearch,
#   ]
# }

# ==============================================================================
# Karpenter
# ==============================================================================
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  namespace        = "kube-system"
  create_namespace = true
  version          = local.chart_versions.karpenter

  wait    = true
  atomic  = true
  timeout = 300

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = module.karpenter.service_account
  }
  set {
    name  = "replicas"
    value = "1"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "250m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "512Mi"
  }

  depends_on = [module.eks, module.karpenter]
}

resource "helm_release" "karpenter_provisioner" {
  name      = "karpenter-provisioner"
  chart     = "${path.module}/karpenter-provisioner"
  namespace = "kube-system"

  wait    = true
  timeout = 120

  set {
    name  = "karpenterRoleName"
    value = module.karpenter.node_iam_role_name
  }
  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "cpuLimit"
    value = var.karpenter_cpu_limit
  }
  set {
    name  = "memoryLimit"
    value = var.karpenter_memory_limit
  }

  depends_on = [helm_release.karpenter]
}
