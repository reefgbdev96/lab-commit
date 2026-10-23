# Privileged role for running Terraform and the make targets. Only the named IAM
# user may assume it, and only with its own name as the session name, so every
# action in CloudTrail is attributable. No MFA condition: the lab user is shared
# with the reviewers, and an MFA device on it would lock them out of the console.
locals {
  operator_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.operator_user}"
}

data "aws_iam_policy_document" "operator_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [local.operator_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:RoleSessionName"
      values   = [var.operator_user]
    }
  }
}

resource "aws_iam_role" "operator" {
  name                 = "${var.operator_user}-lab-admin"
  description          = "Privileged role for the lab"
  assume_role_policy   = data.aws_iam_policy_document.operator_trust.json
  max_session_duration = 14400
}

# Terraform here creates IAM roles, OIDC providers, EKS, RDS, networking and CI:
# a scoped policy would be nearly as broad. The privilege lives behind an explicit role assumption instead.
resource "aws_iam_role_policy_attachment" "operator_admin" {
  role       = aws_iam_role.operator.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
