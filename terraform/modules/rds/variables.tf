variable "name" {
  description = "DB instance identifier."
  type        = string
}

# 17 is what the upstream module example pins. RDS also offers 18; bump only
# after confirming the parameter-group family exists:
#   aws rds describe-db-engine-versions --engine postgres --engine-version 18
variable "engine_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "17"
}

variable "instance_class" {
  description = "Instance class. db.t4g.micro is the cheapest and is free-tier eligible."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20
}

variable "database_name" {
  description = "Initial database name."
  type        = string
  default     = "labdb"
}

variable "username" {
  description = "Master username. The password is generated and held by Secrets Manager."
  type        = string
  default     = "labadmin"
}

variable "private_subnet_ids" {
  description = "Private subnets for the DB subnet group. Two AZs minimum."
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC the database security groups live in."
  type        = string
}

variable "extra_allowed_security_group_ids" {
  description = "Security groups allowed to reach PostgreSQL besides db-client pods (e.g. the jump box), keyed by a static name."
  type        = map(string)
  default     = {}
}

variable "multi_az" {
  description = "Run a standby in a second AZ. Roughly doubles cost; off for a lab."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention. Changing between 0 and non-zero causes an outage, so set it at creation."
  type        = number
  default     = 1
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. True for a lab so teardown is clean."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Block accidental deletion."
  type        = bool
  default     = false
}
