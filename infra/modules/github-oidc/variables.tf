variable "project" {
  description = "Project slug - prefixed onto the OIDC provider + CI role names."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the CI role, in 'owner/name' form."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name the CI role may DescribeCluster (for the deploy step)."
  type        = string
}

variable "ecr_repo_arns" {
  description = "ECR repository ARNs the CI role may push to."
  type        = list(string)
}

variable "region" {
  description = "Primary region (used to scope the eks:DescribeCluster resource ARN)."
  type        = string
}
