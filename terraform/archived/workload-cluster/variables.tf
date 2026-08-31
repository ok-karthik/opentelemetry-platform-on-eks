variable "aws_region" {
  description = "AWS target deployment region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "apps-workload-cluster-1"
}

variable "node_group_name" {
  description = "Name of the EKS managed node group"
  type        = string
  default     = "general-compute-nodes"
}

variable "node_group_instance_types" {
  description = "EC2 instance types for the worker nodes. m7i-flex.large (2 vCPU, 8 GiB) is Free Tier eligible in us-east-1."
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_group_desired_capacity" {
  description = "Initial number of nodes in the node group"
  type        = number
  default     = 2
}

variable "node_group_min_size" {
  description = "Minimum number of nodes for autoscaling"
  type        = number
  default     = 1
}

variable "node_group_max_size" {
  description = "Maximum number of nodes for autoscaling"
  type        = number
  default     = 4
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
