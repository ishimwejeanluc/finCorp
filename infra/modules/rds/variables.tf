variable "project" {
  description = "Project slug - prefixed onto resource names and used as the AWS Backup tag value."
  type        = string
}

variable "vpc_id" {
  description = "VPC the database lives in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs across >= 2 AZs."
  type        = list(string)
  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "An RDS subnet group requires subnets in at least 2 Availability Zones."
  }
}

variable "engine_version" {
  description = "Postgres engine version. List with: aws rds describe-db-engine-versions --engine postgres --region <r>"
  type        = string
  default     = "16.9"
}

variable "instance_class" {
  description = "RDS instance class. db.t3.micro keeps the lab cheap; bump for more throughput."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Initial storage (GiB)."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling (GiB)."
  type        = number
  default     = 100
}

variable "multi_az" {
  description = "Multi-AZ standby in the primary region. Off by default to keep the lab cheap; DR is cross-region via AWS Backup."
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Initial database name created on boot."
  type        = string
  default     = "fincorp"
}

variable "master_username" {
  description = "Master DB username. Cannot be 'postgres', 'admin', 'rdsadmin', etc."
  type        = string
  default     = "fincorp"
}

variable "backup_retention_days" {
  description = "Days of native RDS automated backups to retain (separate from AWS Backup)."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "If true, refuses to delete the instance. Kept FALSE here so the DR simulation can delete the primary."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "If true, no final snapshot at destroy. Kept TRUE so the simulated region failure is a clean delete."
  type        = bool
  default     = true
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights."
  type        = bool
  default     = false
}
