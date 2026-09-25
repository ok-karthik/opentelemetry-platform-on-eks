# ==============================================================================
# Observability Platform Components Variables
# ==============================================================================

variable "aws_region" {
  description = "AWS target deployment region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "deploy_observability_stack" {
  description = "Whether to deploy the observability Helm charts (Loki, Tempo, Mimir, Grafana)"
  type        = bool
  default     = false
}

variable "deploy_opensearch_stack" {
  description = "Whether to deploy the optional enterprise OpenSearch, Dashboards, and Logstash stack"
  type        = bool
  default     = false
}

variable "use_amazon_managed_prometheus" {
  description = "Whether to use Amazon Managed Service for Prometheus (AMP) for metrics instead of self-hosting Mimir"
  type        = bool
  default     = false
}

variable "use_amazon_managed_grafana" {
  description = "Whether to use Amazon Managed Grafana (AMG) workspace instead of deploying self-hosted Grafana in-cluster"
  type        = bool
  default     = false
}

variable "enable_ssm_incident_manager" {
  description = "Whether to provision AWS Systems Manager Incident Manager for multi-AZ/multi-region on-call escalation"
  type        = bool
  default     = true
}

variable "oncall_contact_email" {
  description = "Email address for the primary on-call SRE"
  type        = string
  default     = "sre-oncall@example.com"
}

variable "enable_sre_agent_webhook" {
  description = "Whether to route firing alerts (severity page/ticket) to the SRE agent trigger endpoint"
  type        = bool
  default     = false
}

variable "sre_agent_webhook_url" {
  description = "HTTP webhook URL for the SRE agent incident trigger"
  type        = string
  default     = "http://sre-agent.observability.svc.cluster.local.:8080/webhook"
}

variable "s3_endpoint" {
  description = "Custom S3-compatible storage endpoint (e.g. MinIO minio.observability.svc.cluster.local:9000). Defaults to empty string, which uses standard AWS S3 endpoints."
  type        = string
  default     = ""
}

variable "s3_insecure" {
  description = "Whether to allow insecure HTTP connections to the S3-compatible endpoint (useful for local MinIO testing)"
  type        = bool
  default     = false
}

variable "s3_force_path_style" {
  description = "Whether to force path-style S3 URLs (http://s3.host/bucket/key) required by MinIO"
  type        = bool
  default     = false
}



