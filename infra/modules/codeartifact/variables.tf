variable "project" {
  description = "Project slug. Used as the CodeArtifact domain name."
  type        = string
}

variable "ci_role_arns" {
  description = "IAM role ARNs (e.g. the GitHub Actions CI role) granted read access to the proxy repos via a resource policy. Empty = no resource policy (rely on identity-based IAM)."
  type        = list(string)
  default     = []
}
