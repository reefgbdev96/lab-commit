output "certificate_arn" {
  description = "ACM certificate ARN for the Ingress to reference."
  value       = aws_acm_certificate.this.arn
}

output "zone_id" {
  description = "Private hosted zone ID."
  value       = aws_route53_zone.private.zone_id
}

output "zone_name" {
  description = "Private hosted zone name."
  value       = aws_route53_zone.private.name
}

output "zone_arn" {
  description = "Private hosted zone ARN (scopes external-dns IAM)."
  value       = aws_route53_zone.private.arn
}

output "fqdns" {
  description = "Fully qualified names the certificate covers."
  value       = local.fqdns
}

# Public certificate only: the jump box and the load generator trust it.
output "certificate_pem" {
  description = "Self-signed certificate (public part)."
  value       = tls_self_signed_cert.this.cert_pem
}
