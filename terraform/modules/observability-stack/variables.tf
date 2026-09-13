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

