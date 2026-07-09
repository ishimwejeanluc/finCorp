variable "aws_region" {
  description = "Home region for the persistent/account-level resources and the source AWS Backup vault."
  type        = string
  default     = "eu-west-1"
}

variable "dr_region" {
  description = "DR region. Receives the cross-region AWS Backup copies and the replicated ECR images."
  type        = string
  default     = "eu-west-2"
}

variable "project" {
  description = "Project slug."
  type        = string
  default     = "fincorp"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the CI role, in 'owner/name' form. Case-sensitive."
  type        = string
  default     = "ishimwejeanluc/finCorp"
}

variable "backup_schedule" {
  description = "Cron (UTC) for the daily AWS Backup rule. Default 05:00 UTC daily."
  type        = string
  default     = "cron(0 5 * * ? *)"
}

variable "backup_retention_days" {
  description = "Retention (days) for recovery points in both the primary and DR vaults."
  type        = number
  default     = 7
}
