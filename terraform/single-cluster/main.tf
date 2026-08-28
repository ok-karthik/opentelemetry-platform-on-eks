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

# ==============================================================================
# Amazon Elastic Container Registry (ECR) Repositories
# ==============================================================================

resource "aws_ecr_repository" "golang_product_service" {
  name                 = "golang-product-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_repository" "python_product_info_service" {
  name                 = "python-product-info-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}
