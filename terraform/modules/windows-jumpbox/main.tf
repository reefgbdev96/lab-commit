# Windows jump box for the reviewer: no key pair, no public IP, no inbound port.
# Session Manager is outbound-initiated, and RDP rides an SSM port-forward.
data "aws_ssm_parameter" "windows_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base"
}

resource "aws_security_group" "this" {
  name        = "${var.name}-jumpbox"
  description = "Windows jump box: no inbound; SSM is outbound-initiated"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS: SSM via NAT, Chrome download, the internal ALB, the EKS API"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Windows fetches certificate revocation lists and missing roots over plain HTTP;
# without it the Chrome installer's signature check can fail.
resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.this.id
  description       = "HTTP for CRL/AIA certificate checks"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "postgres" {
  security_group_id = aws_security_group.this.id
  description       = "PostgreSQL to RDS for the SSM database tunnel"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix        = "${var.name}-jumpbox-" # IAM names are account-global; the lab account is shared
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name}-jumpbox-"
  role        = aws_iam_role.this.name
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.windows_ami.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data.ps1.tftpl", {
    trusted_cert_pem = var.trusted_cert_pem
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    encrypted   = true
  }

  tags = {
    Name = "${var.name}-jumpbox"
  }

  # The AMI parameter moves every Patch Tuesday; don't replace the box for it.
  lifecycle {
    ignore_changes = [ami]
  }
}
