# Cross-region DR for the primary RDS database, via AWS Backup.
#
# Flow: daily backup -> recovery point in the PRIMARY vault -> AWS Backup copies
# it to the DR vault in eu-west-2. If the primary region is lost, the database is
# restored from the DR vault's copy (see scripts/dr-restore.sh + dr-restore.yml).
#
# Encrypted recovery points can only be copied cross-region when the source is
# encrypted with a customer-managed KMS key (handled by the rds module) and the
# destination vault has its own KMS key (created here in the DR region).

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.70"
      configuration_aliases = [aws.dr]
    }
  }
}

# ---------- KMS keys (one per region) ----------
resource "aws_kms_key" "primary" {
  description             = "${var.project} primary backup vault key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "${var.project}-backup-primary" }
}

resource "aws_kms_key" "dr" {
  provider                = aws.dr
  description             = "${var.project} DR backup vault key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "${var.project}-backup-dr" }
}

# ---------- Backup vaults ----------
resource "aws_backup_vault" "primary" {
  name        = "${var.project}-backup-primary"
  kms_key_arn = aws_kms_key.primary.arn
}

resource "aws_backup_vault" "dr" {
  provider    = aws.dr
  name        = "${var.project}-backup-dr"
  kms_key_arn = aws_kms_key.dr.arn
}

# ---------- AWS Backup service role ----------
# Name matches the github-oidc PassRole pattern "${project}-backup-*".
data "aws_iam_policy_document" "backup_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.project}-backup-role"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
  tags               = { Name = "${var.project}-backup-role" }
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# ---------- Backup plan: daily + cross-region copy ----------
resource "aws_backup_plan" "this" {
  name = "${var.project}-daily-dr"

  rule {
    rule_name         = "daily-with-cross-region-copy"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = var.schedule
    start_window      = 60  # minutes to start before considered failed
    completion_window = 180 # minutes to complete

    lifecycle {
      delete_after = var.retention_days
    }

    # The cross-region copy that makes DR possible.
    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        delete_after = var.retention_days
      }
    }
  }
}

# ---------- Selection: protect resources tagged Backup = <project> ----------
resource "aws_backup_selection" "this" {
  name         = "${var.project}-rds-selection"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = var.backup_tag_value
  }
}
