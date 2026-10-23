# EKS on Fargate only: the spec forbids node groups, so the cluster has no EC2
# nodes of any kind - every pod runs on Fargate in the private subnets.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # Private-only API: operators reach it through an SSM port-forward via the jump box.
  endpoint_public_access  = false
  endpoint_private_access = true

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Audit + authenticator logs for traceability; the chatty "api" stream and the
  # 90-day default retention would cost more than the lab is worth.
  enabled_log_types                      = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  # No nodes, so no node security group. Fargate pods use the cluster security group.
  create_node_security_group = false

  # The module attaches only AmazonEKSClusterPolicy; SecurityGroupPolicy (per-pod
  # security groups) needs the VPC resource controller as well.
  iam_role_additional_policies = {
    AmazonEKSVPCResourceController = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  }

  # Pod execution roles need only the Fargate policy, not the VPC CNI one (ENI
  # management on "*"). The system profile is at the 5-selector limit.
  fargate_profiles = {
    system = {
      selectors                  = [for ns in ["kube-system", "argocd", "monitoring", "keda", "external-dns"] : { namespace = ns }]
      iam_role_attach_cni_policy = false
    }
    apps = {
      selectors                  = [{ namespace = "demo" }]
      iam_role_attach_cni_policy = false
    }
  }

  # The module installs no self-managed add-ons; CoreDNS is the only one Fargate
  # needs, and it must be told to schedule onto Fargate.
  addons = {
    coredns = {
      configuration_values = jsonencode({ computeType = "Fargate" })
    }
  }

  security_group_additional_rules = {
    for name, sg in var.api_allowed_security_group_ids : "ingress_api_from_${name}" => {
      description              = "Kubernetes API from ${name}"
      type                     = "ingress"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      source_security_group_id = sg
    }
  }
}
