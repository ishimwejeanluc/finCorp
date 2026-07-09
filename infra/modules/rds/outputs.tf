# Instance-level outputs are null in "restore" mode (no instance is created here —
# dr-restore.sh lands it from a backup recovery point).

output "db_address" {
  description = "Instance endpoint (host only). Null in restore mode."
  value       = one(aws_db_instance.this[*].address)
}

output "db_endpoint" {
  description = "host:port form. Null in restore mode."
  value       = local.create ? "${aws_db_instance.this[0].address}:${aws_db_instance.this[0].port}" : null
}

output "db_port" {
  value = one(aws_db_instance.this[*].port)
}

output "db_name" {
  value = one(aws_db_instance.this[*].db_name)
}

output "db_arn" {
  description = "RDS instance ARN - the AWS Backup selection targets this resource. Null in restore mode."
  value       = one(aws_db_instance.this[*].arn)
}

output "db_identifier" {
  description = "RDS instance identifier - used by the DR restore script. Null in restore mode."
  value       = one(aws_db_instance.this[*].identifier)
}

output "kms_key_arn" {
  description = "CMK ARN encrypting the database + its snapshots. Null in restore mode."
  value       = one(aws_kms_key.db[*].arn)
}

output "backup_tag_value" {
  description = "Value of the 'Backup' tag the AWS Backup selection matches on."
  value       = var.project
}

output "security_group_id" {
  description = "RDS SG (always created). The live stack adds an ingress rule from the EKS cluster SG; the restore attaches this SG to the recovered instance."
  value       = aws_security_group.this.id
}

output "db_subnet_group_name" {
  description = "DB subnet group (always created). In the DR region this is the restore landing group."
  value       = aws_db_subnet_group.this.name
}

output "credentials_secret_arn" {
  description = "Secrets Manager ARN holding username/password/DSN. Null in restore mode."
  value       = one(aws_secretsmanager_secret.credentials[*].arn)
}
