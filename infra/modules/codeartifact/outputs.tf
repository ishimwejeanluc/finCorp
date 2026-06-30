output "domain_name" {
  description = "CodeArtifact domain name (pass to `aws codeartifact login --domain`)."
  value       = aws_codeartifact_domain.this.domain
}

output "domain_owner" {
  description = "Account ID that owns the domain."
  value       = data.aws_caller_identity.current.account_id
}

output "npm_repo_name" {
  value = aws_codeartifact_repository.npm.repository
}

output "pypi_repo_name" {
  value = aws_codeartifact_repository.pypi.repository
}
