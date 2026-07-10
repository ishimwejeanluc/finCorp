output "cluster_name" {
  value = module.stack.cluster_name
}

output "kubeconfig_command" {
  description = "Point kubectl at the DR cluster."
  value       = "aws eks update-kubeconfig --name ${module.stack.cluster_name} --region ${var.aws_region}"
}

output "vpc_id" {
  value = module.stack.vpc_id
}

# Consumed by scripts/dr-restore.sh to land + wire the restored DB.
output "rds_db_subnet_group_name" {
  description = "DB subnet group the restored instance is placed into."
  value       = module.stack.rds_db_subnet_group_name
}

output "rds_security_group_id" {
  description = "RDS SG (trusts the DR EKS cluster SG). Attached to the restored instance for local access."
  value       = module.stack.rds_security_group_id
}

output "lb_controller_role_arn" {
  description = "Annotate the aws-load-balancer-controller ServiceAccount with this ARN."
  value       = module.stack.lb_controller_role_arn
}
