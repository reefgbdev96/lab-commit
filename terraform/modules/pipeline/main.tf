# One pipeline per service: a push touching apps/<service>/ builds and pushes an
# immutable image, then CodeBuild commits the new tag to gitops/ and Argo CD
# deploys it. The pipeline never talks to the cluster or the database.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
}

# Starts PENDING: a one-time "Update pending connection" in the console installs the GitHub App.
resource "aws_codeconnections_connection" "github" {
  name          = var.name
  provider_type = "GitHub"
}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.services)

  name                 = "${var.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  # Per repository rather than the registry-wide rule: the account is shared.
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "${var.name}-pipeline-"
  force_destroy = true
}

data "aws_iam_policy_document" "artifacts_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_tls_only.json
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Fine-grained PAT (Contents: write, this repository only) for the GitOps
# write-back. Its value is set out of band with put-secret-value, so it never
# enters Terraform state.
resource "aws_secretsmanager_secret" "github_token" {
  name                    = "${var.name}/github-token"
  recovery_window_in_days = 0 # lab: allow destroy and re-create under the same name
}

resource "aws_codebuild_project" "build" {
  name         = var.name
  service_role = aws_iam_role.build.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "ci/buildspec.yml"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux-x86_64-standard:6.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # runs the Docker daemon for image builds

    environment_variable {
      name  = "ECR_REGISTRY"
      value = local.ecr_registry
    }
    environment_variable {
      name  = "GITHUB_REPOSITORY"
      value = var.github_repository
    }
  }
}

resource "aws_codepipeline" "service" {
  for_each = toset(var.services)

  name          = "${var.name}-${each.key}"
  pipeline_type = "V2"
  role_arn      = aws_iam_role.pipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      namespace        = "SourceVariables"
      output_artifacts = ["source"]
      configuration = {
        ConnectionArn    = aws_codeconnections_connection.github.arn
        FullRepositoryId = var.github_repository
        BranchName       = var.branch
      }
    }
  }

  stage {
    name = "Build"
    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]
      configuration = {
        ProjectName = aws_codebuild_project.build.name
        EnvironmentVariables = jsonencode([
          { name = "SERVICE", value = each.key, type = "PLAINTEXT" },
          { name = "SOURCE_SHA", value = "#{SourceVariables.CommitId}", type = "PLAINTEXT" },
        ])
      }
    }
  }

  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = [var.branch]
        }
        # The tag commit only touches gitops/, so it never re-triggers a pipeline.
        file_paths {
          includes = ["apps/${each.key}/**"]
        }
      }
    }
  }
}
