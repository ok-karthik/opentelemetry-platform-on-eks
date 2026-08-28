# ==============================================================================
# AWS Provider & Data Sources
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

# Configure the Helm provider to authenticate dynamically with EKS
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

# ==============================================================================
# EKS
# ==============================================================================
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.35"

  # Nodes are launched into private subnets and need NAT egress during bootstrap
  # for nodeadm, EC2 API calls, EKS registration, image pulls, and add-ons.
  depends_on = [aws_route_table_association.private]

  # 1. Network setup (passes subnets from your VPC resource)
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private[*].id

  # 2. Grant public access to the EKS endpoint
  cluster_endpoint_public_access = true

  # 3. Configure the Managed Node Group (Spot Instances)
  #
  #    This cluster only runs the two demo services and the DaemonSet collector,
  #    so t3.medium is sufficient. Driven by variables rather than hardcoded so
  #    the node_group_* inputs are actually reachable.
  eks_managed_node_groups = {
    general = {
      name           = var.node_group_name
      min_size       = var.node_group_min_size
      max_size       = var.node_group_max_size
      desired_size   = var.node_group_desired_capacity
      instance_types = var.node_group_instance_types
      capacity_type  = var.node_group_capacity_type
    }
  }

  # Disable KMS encryption to bypass service-linked role permission bottlenecks
  create_kms_key            = false
  cluster_encryption_config = {}

  # 4. Install EKS Add-ons natively.
  #    coredns is listed explicitly for the same reason as on the observability
  #    cluster: in-cluster DNS must be healthy before the cert-manager and OTel
  #    Operator webhook admission calls fire.
  cluster_addons = {
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    eks-pod-identity-agent = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    metrics-server = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  # 5. Enable access entries (Modern EKS auth)
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    console_user = {
      principal_arn = "arn:aws:iam::174160028427:user/ok"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
