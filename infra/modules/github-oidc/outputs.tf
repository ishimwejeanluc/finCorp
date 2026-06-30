output "ci_role_arn" {
  description = "ARN of the GitHub Actions CI role. Set as the AWS_GHA_ROLE_ARN repo variable; the workflows assume it via OIDC."
  value       = aws_iam_role.ci.arn
}

output "ci_role_name" {
  value = aws_iam_role.ci.name
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
