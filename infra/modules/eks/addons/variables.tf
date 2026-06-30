variable "cluster_name" {
  description = "EKS cluster the add-ons install into."
  type        = string
}

variable "node_group_arn" {
  description = "Pass the node group's ARN to force add-ons to wait for nodes before installing (otherwise pods stay Pending)."
  type        = string
}

variable "log_retention_days" {
  description = "Retention for the Container Insights log groups. Default keeps lab cost predictable; the addon would otherwise create them with no expiry."
  type        = number
  default     = 14
}
