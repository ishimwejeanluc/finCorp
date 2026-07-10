variable "project" {
  description = "Project slug - used as the EKS cluster name."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  description = "VPC the cluster runs in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets - EKS uses these for public LBs and control-plane ENIs."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets - worker nodes land here. Must span >= 2 AZs."
  type        = list(string)
}

variable "enable_public_endpoint" {
  description = "Whether the Kubernetes API server is reachable from the public internet."
  type        = bool
  default     = true
}

variable "enabled_log_types" {
  description = "EKS control-plane log types to ship to CloudWatch. Empty = disabled (no CloudWatch Logs cost) — the lean lab default. Set e.g. [\"audit\"] if you need it."
  type        = list(string)
  default     = []
}
