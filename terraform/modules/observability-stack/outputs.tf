# ==============================================================================
# Observability Platform Components Outputs
# ==============================================================================

output "amp_workspace_endpoint" {
  description = "The Prometheus remote-write / query endpoint for Amazon Managed Prometheus"
  value       = var.use_amazon_managed_prometheus ? aws_prometheus_workspace.amp[0].prometheus_endpoint : ""
}

output "amp_workspace_id" {
  description = "The ID of the Amazon Managed Prometheus workspace"
  value       = var.use_amazon_managed_prometheus ? aws_prometheus_workspace.amp[0].id : ""
}

output "loki_bucket_name" {
  description = "Name of the Loki S3 bucket"
  value       = aws_s3_bucket.loki_data.bucket
}

output "tempo_bucket_name" {
  description = "Name of the Tempo S3 bucket"
  value       = aws_s3_bucket.tempo_data.bucket
}

output "grafana_stack_role_arn" {
  description = "IAM Role ARN used by Grafana/Loki/Tempo via Pod Identity"
  value       = aws_iam_role.grafana_stack.arn
}
