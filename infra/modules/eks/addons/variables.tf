variable "cluster_name" {
  description = "EKS cluster the add-ons install into."
  type        = string
}

variable "node_group_arn" {
  description = "Pass the node group's ARN to force add-ons to wait for nodes before installing (otherwise pods stay Pending)."
  type        = string
}
