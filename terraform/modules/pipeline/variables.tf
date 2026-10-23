variable "name" {
  description = "Name prefix; also the ECR repository namespace."
  type        = string
}

variable "services" {
  description = "Services that get an ECR repository and a pipeline; each builds apps/<service>."
  type        = list(string)
}

variable "github_repository" {
  description = "GitHub repository as owner/name."
  type        = string
}

variable "branch" {
  description = "Branch that triggers the pipelines."
  type        = string
}
