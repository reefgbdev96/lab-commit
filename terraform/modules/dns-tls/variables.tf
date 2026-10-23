variable "zone_name" {
  description = "Private hosted zone name, e.g. lab.internal."
  type        = string
}

variable "hostnames" {
  description = "Host labels under zone_name the certificate covers; the first is the certificate CN."
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC the private hosted zone is associated with."
  type        = string
}

variable "organization" {
  description = "Certificate subject organization."
  type        = string
  default     = "CommIT Lab"
}

variable "validity_days" {
  description = "Certificate lifetime. Imported certificates are not auto-renewed."
  type        = number
  default     = 365
}

variable "force_destroy" {
  description = "Delete all records with the zone on destroy. True for a lab."
  type        = bool
  default     = true
}
