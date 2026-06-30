output "primary_vault_name" {
  value = aws_backup_vault.primary.name
}

output "primary_vault_arn" {
  value = aws_backup_vault.primary.arn
}

output "dr_vault_name" {
  description = "DR vault in eu-west-2 - cross-region copies land here; the restore reads from it."
  value       = aws_backup_vault.dr.name
}

output "dr_vault_arn" {
  value = aws_backup_vault.dr.arn
}

output "dr_kms_key_arn" {
  description = "DR-region CMK - pass to the restore as the encryption key for the new instance."
  value       = aws_kms_key.dr.arn
}

output "plan_id" {
  value = aws_backup_plan.this.id
}

output "backup_role_arn" {
  value = aws_iam_role.backup.arn
}
