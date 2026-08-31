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
  default     = "app-workloads-and-observability-cluster"
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
