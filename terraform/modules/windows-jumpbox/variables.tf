variable "name" {
  description = "Name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the jump box security group."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR; the jump box may reach PostgreSQL inside it for the database tunnel."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet for the instance."
  type        = string
}

variable "trusted_cert_pem" {
  description = "Public certificate the jump box adds to its trusted root store."
  type        = string
}

variable "instance_type" {
  description = "Instance type. Windows Server 2025 AMIs require Nitro."
  type        = string
  default     = "t3.medium"
}
