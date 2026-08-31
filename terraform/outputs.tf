# ==============================================================================
# Root Terraform Outputs
# ==============================================================================

output "cluster_name" {
  description = "The name of the unified EKS cluster"
  value       = module.eks_base.cluster_name
}

output "cluster_endpoint" {
  description = "The endpoint URL for the Kubernetes API server"
  value       = module.eks_base.cluster_endpoint
}

output "cluster_arn" {
  description = "The ARN of the EKS cluster"
  value       = module.eks_base.cluster_arn
}

output "kubeconfig_update_command" {
  description = "AWS CLI command to configure local kubectl context"
  value       = module.eks_base.kubeconfig_update_command
}

output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.eks_base.vpc_id
}

output "vpc_cidr" {
  description = "The CIDR block of the VPC"
  value       = module.eks_base.vpc_cidr
}

output "amp_workspace_endpoint" {
  description = "The Prometheus remote-write / query endpoint for Amazon Managed Prometheus"
  value       = module.observability_stack.amp_workspace_endpoint
}

output "amp_workspace_id" {
  description = "The ID of the Amazon Managed Prometheus workspace"
  value       = module.observability_stack.amp_workspace_id
}

output "loki_bucket_name" {
  description = "Name of the Loki S3 bucket"
  value       = module.observability_stack.loki_bucket_name
}

output "tempo_bucket_name" {
  description = "Name of the Tempo S3 bucket"
  value       = module.observability_stack.tempo_bucket_name
}
