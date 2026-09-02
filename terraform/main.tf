# ==============================================================================
# Root Terraform Orchestrator
#
# Provides two primary consumption modes:
# 1. Complete End-to-End Reference Platform (orchestrates eks_base + observability_stack)
# 2. Bring Your Own Cluster (import observability_stack module into an existing EKS cluster)
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Configure the Helm provider to dynamically connect to the EKS cluster
provider "helm" {
  kubernetes {
    host                   = module.eks_base.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_base.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks_base.cluster_name]
      command     = "aws"
    }
  }
}

# ==============================================================================
# 1. Day-1 Base Infrastructure (VPC, EKS 1.35, Nodes, Karpenter, Core Addons)
# ==============================================================================
module "eks_base" {
  source = "./modules/eks-base"

  aws_region                  = var.aws_region
  cluster_name                = var.cluster_name
  node_group_capacity_type    = var.node_group_capacity_type
  node_group_instance_types   = var.node_group_instance_types
  node_group_desired_capacity = var.node_group_desired_capacity
  karpenter_enable_spot       = var.karpenter_enable_spot
}

# ==============================================================================
# 2. Day-2 Observability Platform Stack (AMP, S3, Loki, Tempo, Mimir, Grafana)
# ==============================================================================
module "observability_stack" {
  source = "./modules/observability-stack"

  aws_region                    = var.aws_region
  cluster_name                  = module.eks_base.cluster_name
  deploy_observability_stack    = var.deploy_observability_stack
  deploy_opensearch_stack       = var.deploy_opensearch_stack
  use_amazon_managed_prometheus = var.use_amazon_managed_prometheus
  use_amazon_managed_grafana    = var.use_amazon_managed_grafana

  depends_on = [
    module.eks_base
  ]
}
