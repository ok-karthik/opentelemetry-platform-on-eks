# ==============================================================================
# Single-Cluster EKS Observability Platform & Workloads (Fast Dev / Demo Mode)
#
# Reuses the exact same observability-cluster module and helm values.
# Both monitoring stack (LGTM + OTel Gateway) and workloads run on this cluster.
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
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

module "observability_cluster" {
  source                     = "../observability-cluster"
  aws_region                 = "us-east-1"
  cluster_name               = "observability-cluster"
  deploy_observability_stack = var.deploy_observability_stack
  deploy_opensearch_stack    = var.deploy_opensearch_stack
}

