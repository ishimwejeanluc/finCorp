variable "aws_region" {
  description = "DR region. The stack is rebuilt here on failover; the DB is restored into this VPC."
  type        = string
  default     = "eu-west-2"
}

variable "project" {
  description = "Project slug. Same as primary so image names + cluster name match."
  type        = string
  default     = "fincorp"
}

variable "vpc_cidr" {
  description = "CIDR for the DR VPC. Must NOT overlap the primary VPC (10.20.0.0/16)."
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to span."
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
