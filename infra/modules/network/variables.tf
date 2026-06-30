variable "project" {
  description = "Project slug - prefixed onto resource Name tags."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 recommended."
  type        = string
}

variable "az_count" {
  description = "Number of Availability Zones to span. >= 2 required for Multi-AZ RDS."
  type        = number
  default     = 2
}
