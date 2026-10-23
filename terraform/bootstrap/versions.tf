terraform {
  required_version = ">= 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "eu-west-1"
}

variable "operator_user" {
  description = "IAM user allowed to assume the privileged operator role, e.g. candidate04."
  type        = string
}
