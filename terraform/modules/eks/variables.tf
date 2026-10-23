variable "name" {
  description = "Cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version."
  type        = string
}

variable "vpc_id" {
  description = "VPC to create the cluster in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the control-plane ENIs and Fargate pods."
  type        = list(string)
}

variable "api_allowed_security_group_ids" {
  description = "Security groups allowed to reach the private Kubernetes API on 443, keyed by a static name."
  type        = map(string)
  default     = {}
}
