locals {
  tags = merge(var.tags, {
    Project     = var.name
    Environment = "lab"
    ManagedBy   = "terraform"
  })

  # AZ IDs, not names: names map to different physical AZs in each account.
  azs = slice(data.aws_availability_zones.available.zone_ids, 0, 2)
}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
  # AZs where EKS cannot run control-plane ENIs (EKS user guide, "VPC and subnet requirements").
  exclude_zone_ids = ["use1-az3", "usw1-az2", "cac1-az3"]
}

data "aws_caller_identity" "current" {}

module "network" {
  source = "../../modules/network"

  name                 = var.name
  vpc_cidr             = var.vpc_cidr
  azs                  = local.azs
  private_subnet_cidrs = var.private_subnet_cidrs
  public_subnet_cidr   = var.public_subnet_cidr
}

module "dns_tls" {
  source = "../../modules/dns-tls"

  zone_name = var.zone_name
  hostnames = var.hostnames
  vpc_id    = module.network.vpc_id
}

module "jumpbox" {
  source = "../../modules/windows-jumpbox"

  name             = var.name
  vpc_id           = module.network.vpc_id
  vpc_cidr         = module.network.vpc_cidr_block
  subnet_id        = module.network.private_subnet_ids[0]
  trusted_cert_pem = module.dns_tls.certificate_pem
}

module "eks" {
  source = "../../modules/eks"

  name                           = var.name
  kubernetes_version             = var.kubernetes_version
  vpc_id                         = module.network.vpc_id
  private_subnet_ids             = module.network.private_subnet_ids
  api_allowed_security_group_ids = { jumpbox = module.jumpbox.security_group_id }
}

module "rds" {
  source = "../../modules/rds"

  name                             = "${var.name}-db"
  vpc_id                           = module.network.vpc_id
  private_subnet_ids               = module.network.private_subnet_ids
  extra_allowed_security_group_ids = { jumpbox = module.jumpbox.security_group_id }
}

module "pipeline" {
  source = "../../modules/pipeline"

  name              = var.name
  services          = ["frontend", "backend", "loadgen"]
  github_repository = var.github_repository
  branch            = var.github_branch
}
