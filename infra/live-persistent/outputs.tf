# --- CI/CD (GitHub Actions) ---
output "gha_ci_role_arn" {
  description = "Set as the AWS_GHA_ROLE_ARN repo variable. The regional stacks grant it an EKS access entry; the workflows assume it via OIDC."
  value       = module.github_oidc.ci_role_arn
}

output "oidc_provider_arn" {
  value = module.github_oidc.oidc_provider_arn
}

# --- ECR ---
output "ecr_repository_urls" {
  description = "Image references for the K8s manifests and the GitHub Actions build (primary region)."
  value       = module.ecr.repository_urls
}

# --- CodeArtifact ---
output "codeartifact_domain" {
  value = module.codeartifact.domain_name
}

output "codeartifact_npm_repo" {
  value = module.codeartifact.npm_repo_name
}

output "codeartifact_pypi_repo" {
  value = module.codeartifact.pypi_repo_name
}

# --- Disaster Recovery (AWS Backup) ---
output "backup_vault_primary" {
  value = module.backup.primary_vault_name
}

output "backup_vault_dr" {
  description = "DR backup vault in eu-west-2 — cross-region copies land here; the restore reads from it."
  value       = module.backup.dr_vault_name
}

output "backup_plan_id" {
  value = module.backup.plan_id
}

output "backup_role_arn" {
  description = "AWS Backup service role — passed to start-restore-job by the DR restore script."
  value       = module.backup.backup_role_arn
}

output "dr_kms_key_arn" {
  description = "DR-region CMK used to encrypt the restored instance."
  value       = module.backup.dr_kms_key_arn
}
