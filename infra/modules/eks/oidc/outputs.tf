output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider - use as Federated principal in IRSA role trust policies."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL without the https:// prefix - use in IRSA trust conditions (e.g. <url>:sub)."
  value       = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}
