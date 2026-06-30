variable "project" {
  description = "Project slug - prefixed onto resource names."
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster lives in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs across >= 2 AZs."
  type        = list(string)
  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "ElastiCache Multi-AZ requires subnets in at least 2 AZs."
  }
}

variable "node_type" {
  description = "Cache node size. cache.t4g.micro is the cheapest current-gen Graviton option."
  type        = string
  default     = "cache.t4g.micro"
}

variable "engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.1"
}

variable "num_cache_clusters" {
  description = "Total nodes (primary + replicas). >= 2 required for Multi-AZ."
  type        = number
  default     = 2
}

variable "snapshot_retention_days" {
  description = "Days to retain automated snapshots. 0 disables backups."
  type        = number
  default     = 5
}
