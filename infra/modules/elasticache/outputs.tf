output "primary_endpoint_address" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "port" {
  value = aws_elasticache_replication_group.this.port
}

output "security_group_id" {
  description = "Redis SG. Security module adds an ingress rule from backend SG."
  value       = aws_security_group.this.id
}

output "credentials_secret_arn" {
  description = "Secrets Manager ARN - feed into the ECS task definition's secrets[]."
  value       = aws_secretsmanager_secret.credentials.arn
}
