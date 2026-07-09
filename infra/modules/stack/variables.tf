# The regional application + data stack. Instantiated once per region:
#   - live-primary (eu-west-1, rds_mode = "create")
#   - live-dr      (eu-west-2, rds_mode = "restore")
# The region is governed by the aws provider the root passes in — there is no
# region variable here; everything derives region from that provider.

variable "project" {
  description = "Project slug. Prefixes resource names; also the EKS cluster name and the AWS Backup tag value."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for this region's VPC. Primary and DR must not overlap (10.20.0.0/16 vs 10.40.0.0/16)."
  type        = string
}

variable "az_count" {
  description = "Number of AZs to span. >= 2 for the RDS subnet group and EKS node group HA."
  type        = number
  default     = 2
}

variable "rds_mode" {
  description = "\"create\" builds a fresh DB (primary); \"restore\" builds only the DB landing (subnet group + SG) for the DR restore. Passed straight to the rds module."
  type        = string
  default     = "create"
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

variable "ci_role_arn" {
  description = "GitHub Actions CI role ARN (from the persistent layer). Granted an EKS access entry so the pipeline can kubectl against this cluster."
  type        = string
}
