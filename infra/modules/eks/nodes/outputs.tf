output "node_group_arn" {
  description = "ARN of the managed node group."
  value       = aws_eks_node_group.this.arn
}

output "node_group_name" {
  description = "Name of the node group - useful for `aws eks describe-nodegroup`."
  value       = aws_eks_node_group.this.node_group_name
}

output "node_role_arn" {
  description = "IAM role assumed by the EC2 instances. Attach extra policies to this for app-level AWS access (or prefer IRSA)."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "IAM role name - convenient for IAM CLI commands."
  value       = aws_iam_role.node.name
}
