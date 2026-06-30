output "db_address" {
  description = "Instance endpoint (host only)."
  value       = aws_db_instance.this.address
}

output "db_endpoint" {
  description = "host:port form."
  value       = "${aws_db_instance.this.address}:${aws_db_instance.this.port}"
}

output "db_port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "db_arn" {
  description = "RDS instance ARN - the AWS Backup selection targets this resource."
  value       = aws_db_instance.this.arn
}

output "db_identifier" {
  description = "RDS instance identifier - used by the DR restore script."
  value       = aws_db_instance.this.identifier
}

output "kms_key_arn" {
  description = "CMK ARN encrypting the database + its snapshots."
  value       = aws_kms_key.db.arn
}

output "backup_tag_value" {
  description = "Value of the 'Backup' tag the AWS Backup selection matches on."
  value       = var.project
}

output "security_group_id" {
  description = "RDS SG. The live stack adds an ingress rule from the EKS cluster SG."
  value       = aws_security_group.this.id
}

output "credentials_secret_arn" {
  description = "Secrets Manager ARN holding username/password/DSN."
  value       = aws_secretsmanager_secret.credentials.arn
}
