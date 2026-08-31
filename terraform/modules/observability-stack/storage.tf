# 1. S3 Buckets for LGTM Stack
resource "aws_s3_bucket" "loki_data" {
  bucket_prefix = "${var.cluster_name}-loki-data-"
  force_destroy = true
}

resource "aws_s3_bucket" "tempo_data" {
  bucket_prefix = "${var.cluster_name}-tempo-data-"
  force_destroy = true
}

resource "aws_s3_bucket" "mimir_blocks" {
  count         = var.use_amazon_managed_prometheus ? 0 : 1
  bucket_prefix = "${var.cluster_name}-mimir-blocks-"
  force_destroy = true
}

resource "aws_s3_bucket" "mimir_ruler" {
  count         = var.use_amazon_managed_prometheus ? 0 : 1
  bucket_prefix = "${var.cluster_name}-mimir-ruler-"
  force_destroy = true
}

resource "aws_s3_bucket" "mimir_alertmanager" {
  count         = var.use_amazon_managed_prometheus ? 0 : 1
  bucket_prefix = "${var.cluster_name}-mimir-alert-"
  force_destroy = true
}

# 2. IAM Policy for S3 Access
#    s3:GetBucketLocation is required by Loki on startup to resolve the AWS
#    region from the bucket name. Omitting it causes a 403 CrashLoopBackOff.
#
#    The multipart actions are required by Mimir and Tempo: block and chunk
#    uploads above the SDK's 5 MiB threshold are sent as multipart uploads, and
#    a failed part cannot be cleaned up without s3:AbortMultipartUpload. Without
#    them, compaction appears to succeed while leaving orphaned parts behind and
#    eventually fails with AccessDenied.
data "aws_iam_policy_document" "grafana_stack_s3_access" {
  statement {
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucketMultipartUploads",
      "s3:ListMultipartUploadParts"
    ]
    resources = concat(
      [
        aws_s3_bucket.loki_data.arn,
        "${aws_s3_bucket.loki_data.arn}/*",
        aws_s3_bucket.tempo_data.arn,
        "${aws_s3_bucket.tempo_data.arn}/*",
      ],
      var.use_amazon_managed_prometheus ? [] : [
        aws_s3_bucket.mimir_blocks[0].arn,
        "${aws_s3_bucket.mimir_blocks[0].arn}/*",
        aws_s3_bucket.mimir_ruler[0].arn,
        "${aws_s3_bucket.mimir_ruler[0].arn}/*",
        aws_s3_bucket.mimir_alertmanager[0].arn,
        "${aws_s3_bucket.mimir_alertmanager[0].arn}/*"
      ]
    )
  }
}

resource "aws_iam_policy" "grafana_stack_s3" {
  name        = "${var.cluster_name}-grafana-stack-s3"
  description = "Allow Grafana stack components to access S3"
  policy      = data.aws_iam_policy_document.grafana_stack_s3_access.json
}

# 3. IAM Role for EKS Pod Identity
resource "aws_iam_role" "grafana_stack" {
  name = "${var.cluster_name}-grafana-stack"
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

resource "aws_iam_role_policy_attachment" "grafana_stack_s3_attach" {
  role       = aws_iam_role.grafana_stack.name
  policy_arn = aws_iam_policy.grafana_stack_s3.arn
}

# 4. EKS Pod Identity Associations for the Observability Stack
#    Each individual Helm chart creates its own ServiceAccount (loki, tempo, mimir).
resource "aws_eks_pod_identity_association" "loki" {
  cluster_name    = var.cluster_name
  namespace       = "monitoring"
  service_account = "loki"
  role_arn        = aws_iam_role.grafana_stack.arn
}

resource "aws_eks_pod_identity_association" "tempo" {
  cluster_name    = var.cluster_name
  namespace       = "monitoring"
  service_account = "tempo"
  role_arn        = aws_iam_role.grafana_stack.arn
}

resource "aws_eks_pod_identity_association" "mimir" {
  count           = var.use_amazon_managed_prometheus ? 0 : 1
  cluster_name    = var.cluster_name
  namespace       = "monitoring"
  service_account = "mimir"
  role_arn        = aws_iam_role.grafana_stack.arn
}



