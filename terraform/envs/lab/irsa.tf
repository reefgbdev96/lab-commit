# IRSA roles: Fargate has no EKS Pod Identity, so each workload that calls AWS gets
# a role trusted only by its own Kubernetes service account.
locals {
  db_app_user = "lab_app" # created by db/bootstrap.sql
}

module "lbc_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name                                   = "${var.name}-lbc" # name_prefix limit is 38 chars
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name                          = "${var.name}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [module.dns_tls.zone_arn]

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }
}

# The backend may only log in to this database as the IAM-auth application role.
module "backend_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name                 = "${var.name}-backend"
  create_inline_policy = true
  inline_policy_permissions = {
    ConnectAsAppUser = {
      actions   = ["rds-db:connect"]
      resources = ["arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.rds.resource_id}/${local.db_app_user}"]
    }
  }

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["demo:backend"]
    }
  }
}
