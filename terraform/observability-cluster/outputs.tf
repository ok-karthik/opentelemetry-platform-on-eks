output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "The endpoint URL for the Kubernetes API server"
  value       = module.eks.cluster_endpoint
}

output "cluster_arn" {
  description = "The ARN of the EKS cluster"
  value       = module.eks.cluster_arn
}

output "node_group_name" {
  description = "The name of the managed worker node group"
  value       = "general"
}

output "kubeconfig_update_command" {
  description = "AWS CLI command to configure local kubectl context"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.main.id
}

output "private_route_table_id" {
  description = "The ID of the private route table"
  value       = aws_route_table.private_rt_otel.id
}

output "vpc_cidr" {
  description = "The CIDR block of the VPC"
  value       = local.vpc_cidr
}

output "amp_workspace_endpoint" {
  description = "The Prometheus remote-write / query endpoint for Amazon Managed Prometheus"
  value       = var.use_amazon_managed_prometheus ? aws_prometheus_workspace.amp[0].prometheus_endpoint : ""
}

output "amp_workspace_id" {
  description = "The ID of the Amazon Managed Prometheus workspace"
  value       = var.use_amazon_managed_prometheus ? aws_prometheus_workspace.amp[0].id : ""
}

