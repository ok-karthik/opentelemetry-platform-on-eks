
# ==============================================================================
# Helm Releases — Apps Workload Cluster
#
# Versions are pinned and match the observability cluster. Both clusters run the
# same OTel Operator major, so an Instrumentation CR authored against one is
# valid on the other.
# ==============================================================================

locals {
  chart_versions = {
    cert_manager      = "v1.21.1"
    otel_operator     = "0.120.0"
    aws_lb_controller = "3.4.3"
  }
}

# 1. Deploy Cert-Manager (Required by OTel Operator for webhook TLS certificates)
#
#    wait_for_jobs matters here: the chart installs its CRDs through a Job, and
#    without it Helm reports success while the OTel Operator's webhook
#    registration races the CRDs that have not landed yet.
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

  # Enforce correct destruction order (Helm uninstalled before nodes are deleted)
  depends_on = [module.eks]
}

# 2. Deploy the OpenTelemetry Operator
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

  # The chart defaults to the slim `opentelemetry-collector-k8s` distribution,
  # which omits processors this platform's DaemonSet uses (groupbyattrs among
  # them). Default to contrib so a collector without an explicit `image:` still
  # starts.
  set {
    name  = "manager.collectorImage.repository"
    value = "otel/opentelemetry-collector-contrib"
  }

  # Ensure cert-manager is fully running and nodes are active before installing
  depends_on = [helm_release.cert_manager, module.eks]
}

# 3. Deploy the AWS Load Balancer Controller via Helm
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
    value = var.cluster_name # Your EKS Cluster Name
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

  # The Pod Identity association must exist before the controller pod starts,
  # otherwise it comes up without AWS credentials and sits in a retry loop
  # instead of reconciling the Ingress.
  depends_on = [
    helm_release.cert_manager,
    module.eks,
    aws_eks_pod_identity_association.aws_lb_controller,
  ]
}

# 4.0. Fetch the official AWS Load Balancer Controller IAM Policy
data "http" "aws_lb_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

# Create the IAM Policy in AWS
resource "aws_iam_policy" "aws_lb_controller" {
  name        = "${var.cluster_name}-aws-lb-controller-policy"
  path        = "/"
  description = "IAM policy for the AWS Load Balancer Controller in EKS"
  policy      = data.http.aws_lb_controller_iam_policy.response_body
}

# 4.1. Create the IAM Role with the EKS Pod Identity trust relationship
resource "aws_iam_role" "aws_lb_controller" {
  name = "${var.cluster_name}-aws-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com" # Static, no OIDC variables needed!
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })
}

# 4.2. Attach the Load Balancer Controller IAM Policy to the Role
resource "aws_iam_role_policy_attachment" "aws_lb_controller" {
  policy_arn = aws_iam_policy.aws_lb_controller.arn # Same policy from before
  role       = aws_iam_role.aws_lb_controller.name
}

# 4.3. Associate the Role with the Service Account
resource "aws_eks_pod_identity_association" "aws_lb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_lb_controller.arn
}
