# --- EKS ---
output "cluster_name" {
  value = module.eks_cluster.cluster_name
}

output "cluster_endpoint" {
  value = module.eks_cluster.cluster_endpoint
}

output "cluster_security_group_id" {
  value = module.eks_cluster.cluster_security_group_id
}

output "lb_controller_role_arn" {
  description = "Annotate the aws-load-balancer-controller ServiceAccount with this ARN."
  value       = aws_iam_role.lb_controller.arn
}

# --- Networking ---
output "vpc_id" {
  value = module.network.vpc_id
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

# --- Data tier (RDS) ---
# Instance-level values are null in restore mode (the instance is landed by dr-restore.sh).
output "rds_endpoint" {
  value     = module.rds.db_endpoint
  sensitive = true
}

output "rds_arn" {
  value = module.rds.db_arn
}

output "rds_identifier" {
  value = module.rds.db_identifier
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN for the DB credentials (create mode). Null in restore mode."
  value       = module.rds.credentials_secret_arn
}

output "rds_security_group_id" {
  description = "RDS SG. In DR the restore attaches this to the recovered instance so the app connects locally."
  value       = module.rds.security_group_id
}

output "rds_db_subnet_group_name" {
  description = "DB subnet group. In DR this is the restore landing group."
  value       = module.rds.db_subnet_group_name
}

output "backup_tag_value" {
  description = "The 'Backup' tag value the AWS Backup selection matches on."
  value       = module.rds.backup_tag_value
}

# --- Data tier (Redis) ---
output "redis_endpoint" {
  value     = module.elasticache.primary_endpoint_address
  sensitive = true
}
