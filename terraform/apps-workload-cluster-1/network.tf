# ==============================================================================
# AWS Availability Zones & Region Discovery
# ==============================================================================
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  env      = "dev"
  project  = "apps-workload-cluster-1"
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

# ==============================================================================
# Virtual Private Cloud (VPC)
# ==============================================================================
resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.project}-${local.env}-vpc"
  }
}

# ==============================================================================
# Public Subnets (For load balancers, NAT, IGW)
# ==============================================================================
resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(local.vpc_cidr, 8, count.index + 1) # 10.0.1.0/24, 10.0.2.0/24, etc.
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${local.project}-${local.env}-public-${count.index}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ==============================================================================
# Private Subnets (For EKS Nodes & Pods)
# ==============================================================================
resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, count.index + 10) # 10.0.10.0/24, 10.0.11.0/24, etc. to avoid overlap
  availability_zone = local.azs[count.index]

  tags = {
    Name                                        = "${local.project}-${local.env}-private-${count.index}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  }
}

# ==============================================================================
# Internet Gateway (IGW)
# ==============================================================================
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.project}-${local.env}-igw"
  }
}

# ==============================================================================
# Elastic IP for NAT Gateway
# ==============================================================================
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.project}-${local.env}-nat-eip"
  }
}

# ==============================================================================
# NAT Gateway (For Private Subnets Egress)
# ==============================================================================
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # Placed in the first public subnet

  tags = {
    Name = "${local.project}-${local.env}-nat-gateway"
  }

  depends_on = [aws_internet_gateway.gw]
}

# ==============================================================================
# Route Tables
# ==============================================================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${local.project}-${local.env}-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.project}-${local.env}-private-rt"
  }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

# ==============================================================================
# Route Table Associations
# ==============================================================================
resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ==============================================================================
# S3 Gateway VPC Endpoint (100% Free - Bypasses NAT Gateway for S3)
# ==============================================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.public.id
  ]

  tags = {
    Name = "${local.project}-${local.env}-s3-gateway-endpoint"
  }
}

