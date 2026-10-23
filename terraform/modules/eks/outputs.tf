output "cluster_name" {
  description = "Cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_primary_security_group_id" {
  description = "EKS-created cluster security group. Fargate pods use it unless a SecurityGroupPolicy says otherwise."
  value       = module.eks.cluster_primary_security_group_id
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN. Fargate has no Pod Identity, so workloads use IRSA."
  value       = module.eks.oidc_provider_arn
}
