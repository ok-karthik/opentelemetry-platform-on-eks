# ==============================================================================
# Amazon Managed Service for Prometheus (AMP) & IAM Pod Identity
# ==============================================================================

resource "aws_prometheus_workspace" "amp" {
  count = var.use_amazon_managed_prometheus ? 1 : 0
  alias = "${var.cluster_name}-amp"

  tags = {
    Name        = "${var.cluster_name}-amp"
    Environment = var.environment
  }
}

# ------------------------------------------------------------------------------
# IAM Policy: Allow OTel Gateway to push metrics to AMP & traces to X-Ray
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "otel_gateway_aws_ingest" {
  count       = var.use_amazon_managed_prometheus ? 1 : 0
  name        = "${var.cluster_name}-otel-gateway-aws-ingest"
  description = "Permissions for OTel Gateway to push metrics to AMP and traces to X-Ray"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "aps:RemoteWrite",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata"
        ]
        Resource = [
          aws_prometheus_workspace.amp[0].arn,
          "${aws_prometheus_workspace.amp[0].arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
          "xray:GetSamplingStatisticSummaries"
        ]
        Resource = "*"
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# IAM Role for OTel Gateway Pod Identity
# ------------------------------------------------------------------------------
resource "aws_iam_role" "otel_gateway" {
  count = var.use_amazon_managed_prometheus ? 1 : 0
  name  = "${var.cluster_name}-otel-gateway"

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

resource "aws_iam_role_policy_attachment" "otel_gateway_attach" {
  count      = var.use_amazon_managed_prometheus ? 1 : 0
  role       = aws_iam_role.otel_gateway[0].name
  policy_arn = aws_iam_policy.otel_gateway_aws_ingest[0].arn
}

resource "aws_eks_pod_identity_association" "otel_gateway_tier2" {
  count           = var.use_amazon_managed_prometheus ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = "monitoring"
  service_account = "otel-collector-tier2-processor-collector"
  role_arn        = aws_iam_role.otel_gateway[0].arn
}

# ------------------------------------------------------------------------------
# IAM Policy & Pod Identity for Grafana to Query AMP
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "grafana_amp_query" {
  count       = var.use_amazon_managed_prometheus ? 1 : 0
  name        = "${var.cluster_name}-grafana-amp-query"
  description = "Permissions for Grafana to query metrics from Amazon Managed Prometheus"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata"
        ]
        Resource = [
          aws_prometheus_workspace.amp[0].arn,
          "${aws_prometheus_workspace.amp[0].arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_amp_query_attach" {
  count      = var.use_amazon_managed_prometheus ? 1 : 0
  role       = aws_iam_role.grafana_stack.name
  policy_arn = aws_iam_policy.grafana_amp_query[0].arn
}

resource "aws_eks_pod_identity_association" "grafana" {
  count           = var.use_amazon_managed_prometheus ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = "monitoring"
  service_account = "grafana"
  role_arn        = aws_iam_role.grafana_stack.arn
}
