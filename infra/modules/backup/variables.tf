variable "project" {
  description = "Project slug - prefixed onto vault/role/plan names."
  type        = string
}

variable "protected_db_arn" {
  description = "ARN of the RDS instance being protected. Informational / forces dependency ordering."
  type        = string
}

variable "backup_tag_value" {
  description = "Value of the 'Backup' tag the selection matches (the RDS module tags the DB with this)."
  type        = string
}

variable "schedule" {
  description = "Cron (UTC) for the daily backup rule."
  type        = string
  default     = "cron(0 5 * * ? *)"
}

variable "retention_days" {
  description = "Days to retain recovery points in both the primary and DR vaults."
  type        = number
  default     = 7
}
