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

  # 3. Configure the Managed Node Group
  #
  #    Sized against the measured footprint of the trimmed stack, not a guess.
  #    Summed pod requests across the observability namespace and the platform
  #    add-ons come to roughly 1.8 vCPU and 4.4 GiB:
  #
  #      Mimir (8 pods)   0.40 vCPU / 1728 MiB
  #      Loki  (1 pod)    0.10 vCPU /  256 MiB
  #      Tempo (1 pod)    0.10 vCPU /  256 MiB
  #      Grafana          0.05 vCPU /  192 MiB
  #      OTel gateway x2  0.20 vCPU /  512 MiB
  #      Karpenter        0.25 vCPU /  256 MiB
  #      cert-manager, OTel operator, LB controller, CoreDNS, EBS CSI, agents
  #
  #    t3.medium (4 GiB, ~3.2 GiB allocatable) x2 leaves no headroom for
  #    Mimir compaction spikes or a spot reclaim, and PVC-bound StatefulSets
  #    cannot be rescheduled freely. t3.large (8 GiB) x2 gives ~14 GiB.
  #
  #    Karpenter scales OUT beyond these two nodes whenever a pod goes Pending.
  eks_managed_node_groups = {
    general = {
      name           = var.node_group_name
      min_size       = var.node_group_min_size
      max_size       = var.node_group_max_size
      desired_size   = var.node_group_desired_capacity
      instance_types = var.node_group_instance_types
      capacity_type  = var.node_group_capacity_type
      iam_role_additional_policies = {
        ebs = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }

      # Prevent Karpenter-driven desired_size changes from triggering
      # a destructive node group re-create on the next `terraform apply`.
      lifecycle = {
        ignore_changes = ["scaling_config[0].desired_size"]
      }
    }
  }

  # Disable KMS encryption to bypass service-linked role permission bottlenecks
  create_kms_key            = false
  cluster_encryption_config = {}

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  # 4. Install EKS Add-ons natively.
  #    coredns is explicitly set so in-cluster DNS is healthy before Helm webhook
  #    admission calls fire (cert-manager, OTel Operator).
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
    aws-ebs-csi-driver = {
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
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  # 6. Allow OTel traffic from peered Apps VPC
  node_security_group_additional_rules = {
    ingress_peering_otel = {
      description = "Allow OTel traffic from peered Apps VPC"
      protocol    = "tcp"
      from_port   = 4317
      to_port     = 4318
      type        = "ingress"
      cidr_blocks = ["10.0.0.0/16"]
    }
    ingress_peering_nodeports = {
      description = "Allow NodePort traffic from peered Apps VPC"
      protocol    = "tcp"
      from_port   = 30000
      to_port     = 32767
      type        = "ingress"
      cidr_blocks = ["10.0.0.0/16"]
    }
  }
}

# ==============================================================================
# Karpenter IAM & SQS Configuration
# ==============================================================================
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  # Enable Pod Identity for Karpenter controller
  enable_pod_identity             = true
  create_pod_identity_association = true

  # Attach additional policies to the nodes Karpenter creates
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    AmazonEBSCSIDriverPolicy     = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  }

  tags = {
    Environment = "observability"
  }
}
