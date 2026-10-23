# ACM cannot DNS-validate a name in a private hosted zone, so the certificate is
# self-signed and imported. dns_names is what makes it X.509 v3 - ACM rejects v1
# certificates, which is what a bare `openssl req -x509` produces.
locals {
  # Lowercase: Kubernetes rejects uppercase Ingress hosts, and DNS is
  # case-insensitive, so Lab-commit-task.<zone> still resolves and matches.
  fqdns = [for h in var.hostnames : lower("${h}.${var.zone_name}")]
}

resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "this" {
  private_key_pem = tls_private_key.this.private_key_pem

  subject {
    common_name  = local.fqdns[0]
    organization = var.organization
  }

  dns_names             = local.fqdns
  validity_period_hours = var.validity_days * 24
  set_subject_key_id    = true

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# Imported certificates get no managed renewal: re-run Terraform before expiry.
# validation_method must stay unset for imports.
resource "aws_acm_certificate" "this" {
  private_key      = tls_private_key.this.private_key_pem
  certificate_body = tls_self_signed_cert.this.cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

# Private zone: the name resolves inside the VPC and nowhere else, which is what
# keeps the service off the internet.
resource "aws_route53_zone" "private" {
  name          = var.zone_name
  force_destroy = var.force_destroy

  vpc {
    vpc_id = var.vpc_id
  }
}
