output "bucket" {
  description = "State bucket for terraform/envs/lab."
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  value = var.region
}

output "operator_role_arn" {
  description = "Role to assume for everything after the bootstrap."
  value       = aws_iam_role.operator.arn
}
