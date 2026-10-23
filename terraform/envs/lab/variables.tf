variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "lab-commit"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "Private subnets holding every workload, one per AZ."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidr" {
  description = "The single public subnet. NAT gateway only, no workloads."
  type        = string
  default     = "10.0.101.0/24"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.36"
}

variable "zone_name" {
  description = "Private hosted zone name."
  type        = string
  default     = "lab.internal"
}

variable "hostnames" {
  description = "Hosts served by the internal ALB; the first is the application (Lab-commit-task.<zone>)."
  type        = list(string)
  default     = ["lab-commit-task", "grafana", "argocd"]
}

variable "github_repository" {
  description = "GitHub repository holding this code, as owner/name."
  type        = string
}

variable "github_branch" {
  description = "Branch the pipelines build and Argo CD follows."
  type        = string
  default     = "main"
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}
