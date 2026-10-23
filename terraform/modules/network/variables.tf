variable "name" {
  description = "Name prefix for all network resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "azs" {
  description = "Availability zone IDs. Two minimum: RDS requires a subnet group spanning two AZs."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least two availability zones are required for the RDS subnet group."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDRs for the private subnets that hold every workload, one per AZ."
  type        = list(string)
}

variable "public_subnet_cidr" {
  description = "CIDR for the single public subnet. It hosts only the NAT gateway."
  type        = string
}
