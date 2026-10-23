data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
    # Confused-deputy guard: only this account's pipelines/builds may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name_prefix        = "${var.name}-pipeline-" # IAM names are account-global; the lab account is shared
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "GitHubConnection"
    actions   = ["codeconnections:UseConnection", "codestar-connections:UseConnection"]
    resources = [aws_codeconnections_connection.github.arn]
  }
  statement {
    sid       = "Build"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.build.arn]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

data "aws_iam_policy_document" "build_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    # Confused-deputy guard: only this account's pipelines/builds may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "build" {
  name_prefix        = "${var.name}-build-"
  assume_role_policy = data.aws_iam_policy_document.build_assume.json
}

data "aws_iam_policy_document" "build" {
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.name}*",
    ]
  }
  statement {
    sid       = "SourceArtifact"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # account-level call; cannot be scoped to a repository
  }
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for repo in aws_ecr_repository.this : repo.arn]
  }
  statement {
    sid       = "GitOpsWriteBackToken"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.github_token.arn]
  }
}

resource "aws_iam_role_policy" "build" {
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.build.json
}
