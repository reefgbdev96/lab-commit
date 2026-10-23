# VPC with workloads in private subnets only. The single public subnet exists
# solely to host the NAT gateway - nothing is ever scheduled into it - so egress
# works while nothing in the account is reachable from the internet.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7.3"

  name = var.name
  cidr = var.vpc_cidr
  azs  = var.azs

  private_subnets = var.private_subnet_cidrs
  # NAT only. For HA add one public subnet per AZ and set one_nat_gateway_per_az.
  public_subnets = [var.public_subnet_cidr]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # The load balancer controller discovers subnets for internal ALBs by this tag.
  # Public subnets get no kubernetes.io/role/elb tag, so an internet-facing ALB
  # has nowhere to land even if one were requested.
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

data "aws_region" "current" {}

# Free; keeps ECR image-layer pulls (S3) off the NAT gateway.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}
