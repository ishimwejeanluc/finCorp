# --- EKS cluster ---

output "cluster_name" {
  description = "EKS cluster name. Feed into `aws eks update-kubeconfig`."
  value       = module.eks_cluster.cluster_name
}

output "cluster_endpoint" {
  value = module.eks_cluster.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run this once to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks_cluster.cluster_name} --region ${var.aws_region}"
}

# --- Networking ---

output "vpc_id" {
  value = module.network.vpc_id
}

# --- ECR (where the pipeline pushes immutable images) ---

output "ecr_repository_urls" {
  description = "Image references for the K8s Deployment manifests and the GitHub Actions build."
  value       = module.ecr.repository_urls
}

# --- CI/CD (GitHub Actions) ---

output "gha_ci_role_arn" {
  description = "Set this as the AWS_GHA_ROLE_ARN repo variable in GitHub. The workflows assume it via OIDC."
  value       = module.github_oidc.ci_role_arn
}

output "codeartifact_domain" {
  value = module.codeartifact.domain_name
}

output "codeartifact_npm_repo" {
  value = module.codeartifact.npm_repo_name
}

output "codeartifact_pypi_repo" {
  value = module.codeartifact.pypi_repo_name
}

# --- Data tier ---

output "rds_endpoint" {
  value     = module.rds.db_endpoint
  sensitive = true
}

output "rds_arn" {
  value = module.rds.db_arn
}

output "rds_secret_arn" {
  description = "Read with `aws secretsmanager get-secret-value` to populate the K8s app Secret."
  value       = module.rds.credentials_secret_arn
}

output "redis_endpoint" {
  value     = module.elasticache.primary_endpoint_address
  sensitive = true
}

# --- Disaster Recovery (AWS Backup) ---

output "backup_vault_primary" {
  description = "Source backup vault in the primary region."
  value       = module.backup.primary_vault_name
}

output "backup_vault_dr" {
  description = "DR backup vault in eu-west-2 — cross-region copies land here."
  value       = module.backup.dr_vault_name
}

output "backup_plan_id" {
  value = module.backup.plan_id
}

output "backup_role_arn" {
  description = "AWS Backup service role - passed to start-restore-job by the DR restore script."
  value       = module.backup.backup_role_arn
}

output "dr_db_subnet_group" {
  description = "DB subnet group in eu-west-2 the restored instance is placed into."
  value       = aws_db_subnet_group.dr.name
}

output "dr_kms_key_arn" {
  description = "DR-region CMK used to encrypt the restored instance."
  value       = module.backup.dr_kms_key_arn
}

# --- IRSA role for the AWS Load Balancer Controller ---

output "lb_controller_role_arn" {
  description = "Annotate the aws-load-balancer-controller ServiceAccount with this ARN."
  value       = aws_iam_role.lb_controller.arn
}
