variable "aws_region" {
  description = "Primary AWS region. Hosts EKS, the primary RDS database, and the source AWS Backup vault."
  type        = string
  default     = "eu-west-1"
}

variable "dr_region" {
  description = "Disaster-recovery region. Receives the cross-region AWS Backup copies and is where the database is restored on failover."
  type        = string
  default     = "eu-west-2"
}

variable "project" {
  description = "Project slug. 'fincorp' keeps every resource name distinct from the shopnow-eks lab so both can coexist in one AWS account."
  type        = string
  default     = "fincorp"
}

variable "vpc_cidr" {
  description = "CIDR for the FinCorp VPC. Must NOT overlap with the shopnow-eks VPC (10.1.0.0/16) or shopnow's (10.0.0.0/16)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to span. >= 2 for the RDS subnet group and EKS node group HA."
  type        = number
  default     = 2
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.32"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Initial node count."
  type        = number
  default     = 2
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the CI role, in 'owner/name' form. Scopes the OIDC trust policy. Case-sensitive — must match the repo's exact case (the OIDC 'sub' claim preserves it)."
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
