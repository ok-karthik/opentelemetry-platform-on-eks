# ==============================================================================
# Local Rendering Harness
# Uses real Terraform templatefile() engine to render Helm values templates (.tftpl)
# with local portability context (MinIO endpoint, insecure HTTP, path-style S3).
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
}

locals {
  context = {
    loki_bucket               = "loki-data"
    tempo_bucket              = "tempo-data"
    mimir_blocks_bucket       = "mimir-blocks"
    mimir_ruler_bucket        = "mimir-ruler"
    mimir_alertmanager_bucket = "mimir-alertmanager"
    aws_region                = "us-east-1"
    s3_endpoint               = "minio.observability.svc.cluster.local:9000"
    s3_insecure               = true
    s3_force_path_style       = true
    use_amp                   = false
    amp_workspace_endpoint    = ""
    enable_sre_agent_webhook  = false
    sre_agent_webhook_url     = "http://sre-agent.observability.svc.cluster.local.:8080/webhook"
  }

  tftpl_dir = "${path.module}/../../terraform/modules/observability-stack/helm-values"
}

output "loki" {
  value = templatefile("${local.tftpl_dir}/loki.yaml.tftpl", local.context)
}

output "tempo" {
  value = templatefile("${local.tftpl_dir}/tempo.yaml.tftpl", local.context)
}

output "mimir" {
  value = templatefile("${local.tftpl_dir}/mimir.yaml.tftpl", local.context)
}

output "grafana" {
  value = templatefile("${local.tftpl_dir}/grafana.yaml.tftpl", local.context)
}
