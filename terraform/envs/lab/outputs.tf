# Everything `make gitops-env` and the operator targets need. No secrets: the
# certificate is the public part, and the DB password stays in Secrets Manager.

output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr_block
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_primary_security_group_id" {
  value = module.eks.cluster_primary_security_group_id
}

output "jumpbox_instance_id" {
  value = module.jumpbox.instance_id
}

output "rds_address" {
  value = module.rds.address
}

output "rds_master_secret_arn" {
  value = module.rds.master_user_secret_arn
}

output "db_client_security_group_id" {
  value = module.rds.client_security_group_id
}

output "db_app_user" {
  value = local.db_app_user
}

output "certificate_arn" {
  value = module.dns_tls.certificate_arn
}

output "certificate_pem" {
  value = module.dns_tls.certificate_pem
}

output "zone_name" {
  value = module.dns_tls.zone_name
}

output "ecr_registry" {
  value = module.pipeline.ecr_registry
}

output "codeconnection_arn" {
  value = module.pipeline.connection_arn
}

output "github_token_secret_name" {
  value = module.pipeline.github_token_secret_name
}

output "lbc_role_arn" {
  value = module.lbc_irsa.arn
}

output "external_dns_role_arn" {
  value = module.external_dns_irsa.arn
}

output "backend_role_arn" {
  value = module.backend_irsa.arn
}
