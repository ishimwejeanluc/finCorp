variable "project" {
  description = "Project slug - prefixed onto resource names."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster the node group joins."
  type        = string
}

variable "node_group_name" {
  description = "Logical name for this node group. A cluster can have many."
  type        = string
  default     = "default"
}

variable "private_subnet_ids" {
  description = "Private subnets the nodes attach to."
  type        = list(string)
}

variable "instance_types" {
  description = "EC2 instance types for the nodes. The first available is used."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "ami_type" {
  description = "EKS-managed AMI variant. AL2023 is the current default for x86. Use AL2023_ARM_64_STANDARD for Graviton."
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"
}

variable "desired_size" {
  description = "Initial node count."
  type        = number
  default     = 2
}

variable "min_size" {
  description = "Autoscaling lower bound."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Autoscaling upper bound."
  type        = number
  default     = 3
}

variable "disk_size_gb" {
  description = "Root EBS volume size per node."
  type        = number
  default     = 20
}
