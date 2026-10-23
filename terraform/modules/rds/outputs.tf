output "endpoint" {
  description = "Connection endpoint, host:port."
  value       = module.db.db_instance_endpoint
}

output "address" {
  description = "Hostname of the instance."
  value       = module.db.db_instance_address
}

output "port" {
  description = "Port the instance listens on."
  value       = module.db.db_instance_port
}

output "database_name" {
  description = "Initial database name."
  value       = module.db.db_instance_name
}

output "username" {
  description = "Master username."
  value       = module.db.db_instance_username
  sensitive   = true
}

# The master password lives only in Secrets Manager; make db-bootstrap reads it
# to create the schema and the IAM-auth application role.
output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the master credentials (used by make db-bootstrap)."
  value       = module.db.db_instance_master_user_secret_arn
}

output "resource_id" {
  description = "DbiResourceId, used in the rds-db:connect IAM policy ARN."
  value       = module.db.db_instance_resource_id
}

output "client_security_group_id" {
  description = "Security group that grants PostgreSQL access; attach it to backend pods."
  value       = aws_security_group.client.id
}
