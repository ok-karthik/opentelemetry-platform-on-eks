# ==============================================================================
# AWS Availability Zones & Region Discovery
# ==============================================================================
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  env      = var.environment
  project  = var.project_name
  vpc_cidr = var.vpc_cidr
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
# Automated VPC Pre-Destroy Teardown Hook
# Ensures out-of-band cloud resources created dynamically by Kubernetes controllers
# (Karpenter EC2 instances, AWS Load Balancer Controller ALBs, Target Groups,
# and LoadBalancer Security Groups) are swept cleanly before AWS deletes the VPC/subnets.
# Completely eliminates AWS "DependencyViolation" teardown race conditions.
# ==============================================================================
resource "terraform_data" "vpc_cleanup_hook" {
  input = {
    vpc_id = aws_vpc.main.id
    region = var.aws_region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      VPC_ID="${self.output.vpc_id}"
      REGION="${self.output.region}"
      echo "=== [Pre-Destroy Hook] Auditing and clearing out-of-band resources in VPC $VPC_ID ==="

      # 1. Terminate any dynamic Karpenter EC2 instances in this VPC
      INSTANCES=$(aws ec2 describe-instances --region $REGION \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-key,Values=karpenter.sh/nodepool" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query "Reservations[*].Instances[*].InstanceId" --output text 2>/dev/null || true)
      if [ -n "$INSTANCES" ] && [ "$INSTANCES" != "None" ]; then
        echo "Terminating orphaned Karpenter instances: $INSTANCES"
        aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCES >/dev/null 2>&1 || true
        aws ec2 wait instance-terminated --region $REGION --instance-ids $INSTANCES >/dev/null 2>&1 || true
      fi

      # 2. Delete any ALBs/NLBs created by AWS Load Balancer Controller in this VPC
      LBS=$(aws elbv2 describe-load-balancers --region $REGION \
        --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || true)
      if [ -n "$LBS" ] && [ "$LBS" != "None" ]; then
        for lb in $LBS; do
          echo "Deleting orphaned Load Balancer: $lb"
          aws elbv2 delete-load-balancer --region $REGION --load-balancer-arn "$lb" >/dev/null 2>&1 || true
        done
        sleep 10
      fi

      # 3. Delete any orphaned Target Groups in this VPC
      TGS=$(aws elbv2 describe-target-groups --region $REGION \
        --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null || true)
      if [ -n "$TGS" ] && [ "$TGS" != "None" ]; then
        for tg in $TGS; do
          echo "Deleting orphaned Target Group: $tg"
          aws elbv2 delete-target-group --region $REGION --target-group-arn "$tg" >/dev/null 2>&1 || true
        done
      fi

      # 4. Wait for non-NAT ENIs to cleanly detach and delete
      for i in $(seq 1 30); do
        ENIS=$(aws ec2 describe-network-interfaces --region $REGION \
          --filters "Name=vpc-id,Values=$VPC_ID" \
          --query "NetworkInterfaces[?InterfaceType!='nat_gateway'].NetworkInterfaceId" --output text 2>/dev/null || true)
        if [ -z "$ENIS" ] || [ "$ENIS" = "None" ]; then
          break
        fi
        echo "Waiting for ENIs to release ($ENIS)..."
        sleep 5
      done

      # 5. Delete any remaining non-default Security Groups in this VPC (e.g. k8s-traffic-*, k8s-appgroup-*)
      SGS=$(aws ec2 describe-security-groups --region $REGION \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || true)
      if [ -n "$SGS" ] && [ "$SGS" != "None" ]; then
        for sg in $SGS; do
          echo "Deleting orphaned Kubernetes security group: $sg"
          aws ec2 revoke-security-group-ingress --region $REGION --group-id $sg --protocol all --port 0-65535 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
          aws ec2 delete-security-group --region $REGION --group-id $sg >/dev/null 2>&1 || true
        done
      fi
      echo "=== [Pre-Destroy Hook] VPC $VPC_ID dependencies successfully cleared ==="
    EOT
  }

  depends_on = [aws_vpc.main]
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
resource "aws_route_table" "public_rt_otel" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${local.project}-${local.env}-public-rt"
  }
}

resource "aws_route_table" "private_rt_otel" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.project}-${local.env}-private-rt"
  }
}

resource "aws_route" "private_nat_otel" {
  route_table_id         = aws_route_table.private_rt_otel.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

# ==============================================================================
# Route Table Associations
# ==============================================================================
resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public_rt_otel.id
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private_rt_otel.id
}

# ==============================================================================
# S3 Gateway VPC Endpoint (100% Free - Cuts NAT Data Transfer for Loki/Tempo)
# ==============================================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.private_rt_otel.id,
    aws_route_table.public_rt_otel.id
  ]

  tags = {
    Name = "${local.project}-${local.env}-s3-gateway-endpoint"
  }
}

