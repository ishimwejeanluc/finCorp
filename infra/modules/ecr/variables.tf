variable "project" {
  description = "Project slug - prefixed onto each repo name (e.g. shopnow/frontend)."
  type        = string
}

variable "repositories" {
  description = "Service names to create repos for. Each becomes <project>/<name> in ECR."
  type        = set(string)
  default     = ["frontend", "backend"]
}

variable "max_image_count" {
  description = "How many tagged images to retain per repo before the lifecycle policy expires the oldest."
  type        = number
  default     = 10
}

variable "untagged_expiry_days" {
  description = "Days to retain images that have no tags (typically failed builds or replaced :latest)."
  type        = number
  default     = 1
}
