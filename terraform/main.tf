# ==============================================================================
# Root Terraform Orchestrator for Multi-Cluster EKS Observability Sandbox
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

# ==============================================================================
# 1. Instantiate Application EKS Cluster Module
# ==============================================================================
module "apps_workload_cluster_1" {
  source       = "./apps-workload-cluster-1"
  aws_region   = "us-east-1"
  cluster_name = "apps-workload-cluster-1"
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

# ==============================================================================
# 2. Instantiate Monitoring (OTel/LGTM) EKS Cluster Module
# ==============================================================================
module "observability_cluster" {
  source                     = "./observability-cluster"
  aws_region                 = "us-east-1"
  cluster_name               = "observability-cluster"
  deploy_observability_stack = var.deploy_observability_stack
  deploy_opensearch_stack    = var.deploy_opensearch_stack
}

# ==============================================================================
# 3. Establish VPC Peering Connection between both EKS Cluster VPCs
# ==============================================================================
resource "aws_vpc_peering_connection" "peering" {
  vpc_id      = module.apps_workload_cluster_1.vpc_id
  peer_vpc_id = module.observability_cluster.vpc_id
  auto_accept = true

  tags = {
    Name = "eks-apps-to-otel-peering"
  }
}

# ==============================================================================
# 4. Route Table Entries (Let VPC A and VPC B talk privately)
# ==============================================================================

# Route from Apps VPC to OTel VPC
resource "aws_route" "apps_to_otel" {
  route_table_id            = module.apps_workload_cluster_1.private_route_table_id
  destination_cidr_block    = module.observability_cluster.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peering.id
}

# Route from OTel VPC to Apps VPC
resource "aws_route" "otel_to_apps" {
  route_table_id            = module.observability_cluster.private_route_table_id
  destination_cidr_block    = module.apps_workload_cluster_1.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peering.id
}
