output "ecr_registry" {
  description = "ECR registry host for image references."
  value       = local.ecr_registry
}

output "connection_arn" {
  description = "GitHub connection; approve it once in the console."
  value       = aws_codeconnections_connection.github.arn
}

output "github_token_secret_name" {
  description = "Secret to fill with the write-back PAT via put-secret-value."
  value       = aws_secretsmanager_secret.github_token.name
}

output "pipeline_names" {
  description = "Pipeline per service."
  value       = { for svc, p in aws_codepipeline.service : svc => p.name }
}
