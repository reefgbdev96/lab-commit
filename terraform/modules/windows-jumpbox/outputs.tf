output "instance_id" {
  description = "Instance ID; the SSM session and port-forward target."
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Jump box security group, allowed into the EKS API and PostgreSQL."
  value       = aws_security_group.this.id
}
