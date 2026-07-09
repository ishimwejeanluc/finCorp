output "cluster_name" {
  value = module.stack.cluster_name
}

output "kubeconfig_command" {
  description = "Point kubectl at the primary cluster."
  value       = "aws eks update-kubeconfig --name ${module.stack.cluster_name} --region ${var.aws_region}"
}

output "vpc_id" {
  value = module.stack.vpc_id
}

output "rds_endpoint" {
  value     = module.stack.rds_endpoint
  sensitive = true
}

output "rds_arn" {
  value = module.stack.rds_arn
}

output "rds_secret_arn" {
  value = module.stack.rds_secret_arn
}

output "redis_endpoint" {
  value     = module.stack.redis_endpoint
  sensitive = true
}

output "lb_controller_role_arn" {
  description = "Annotate the aws-load-balancer-controller ServiceAccount with this ARN."
  value       = module.stack.lb_controller_role_arn
}
