# ==============================================================================
# Root Terraform Variables
# ==============================================================================

variable "aws_region" {
  description = "AWS target deployment region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the unified EKS cluster"
  type        = string
  default     = "observability-cluster"
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


variable "node_group_capacity_type" {
  description = "Pricing model for EKS worker nodes (SPOT or ON_DEMAND)"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.node_group_capacity_type)
    error_message = "node_group_capacity_type must be either SPOT or ON_DEMAND."
  }
}

variable "karpenter_enable_spot" {
  description = "Whether Karpenter should provision Spot instances alongside on-demand"
  type        = bool
  default     = false
}

variable "node_group_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_group_desired_capacity" {
  description = "Initial number of worker nodes in the node group"
  type        = number
  default     = 2
}

variable "admin_access_principals" {
  description = "Map of IAM principal ARNs to grant EKS Cluster Admin access"
  type        = map(string)
  default     = {}
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


