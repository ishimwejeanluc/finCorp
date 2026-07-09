locals {
  name = "${var.project}-db"
  # In "restore" mode only the plumbing (subnet group + SG) is created; the instance,
  # its CMK, parameter group, generated password and credentials secret are skipped
  # because scripts/dr-restore.sh lands the instance from a backup recovery point.
  create = var.rds_mode == "create"
}

# ---------- Generated master password (create mode only) ----------
# Excludes characters that confuse DSN parsers (@ : / ?).
resource "random_password" "master" {
  count            = local.create ? 1 : 0
  length           = 32
  special          = true
  override_special = "!#%^*-_=+"
}

# ---------- Customer-managed KMS key (create mode only) ----------
# A CMK (not the default aws/rds key) is REQUIRED for AWS Backup to copy the
# encrypted recovery point to another region. This is the linchpin of the DR plan.
resource "aws_kms_key" "db" {
  count                   = local.create ? 1 : 0
  description             = "CMK for ${local.name} storage + snapshots (enables cross-region backup copy)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "${local.name}-kms" }
}

resource "aws_kms_alias" "db" {
  count         = local.create ? 1 : 0
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.db[0].key_id
}

# ---------- Subnet group (always — the restore lands the instance here) ----------
resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "${local.name}-subnets" }
}

# ---------- Security group (always; the live stack adds ingress from the EKS cluster SG) ----------
# In restore mode dr-restore.sh attaches this SG to the restored instance so the
# rebuilt app connects locally, same-VPC.
resource "aws_security_group" "this" {
  name        = "${local.name}-sg"
  description = "RDS Postgres - ingress added by the live stack"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-sg" }
}

# ---------- Parameter group (create mode only) ----------
resource "aws_db_parameter_group" "this" {
  count       = local.create ? 1 : 0
  name        = "${local.name}-params"
  family      = "postgres16"
  description = "Postgres 16 params for ${var.project}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------- RDS Postgres instance (create mode only, the DR-protected database) ----------
# deletion_protection = false and skip_final_snapshot = true on purpose: the DR
# simulation destroys this instance (with the whole primary stack) to mimic a region failure.
resource "aws_db_instance" "this" {
  count          = local.create ? 1 : 0
  identifier     = local.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.db[0].arn

  db_name  = var.db_name
  username = var.master_username
  password = random_password.master[0].result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this[0].name
  multi_az               = var.multi_az
  publicly_accessible    = false

  # Native automated backups stay on, but cross-region DR is handled by AWS Backup.
  backup_retention_period = var.backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:30-mon:05:30"
  copy_tags_to_snapshot   = true

  performance_insights_enabled = var.performance_insights_enabled
  auto_minor_version_upgrade   = true

  deletion_protection = var.deletion_protection
  skip_final_snapshot = var.skip_final_snapshot

  # The AWS Backup selection matches on this tag.
  tags = {
    Name   = local.name
    Backup = var.project
  }

  lifecycle {
    ignore_changes = [password]
  }
}

# ---------- Secrets Manager (create mode only) ----------
# On failover the restored instance's password is reset by dr-restore.sh, which
# writes a fresh ${project}/rds/credentials secret in the DR region — so this
# primary-region secret is not needed for recovery.
resource "aws_secretsmanager_secret" "credentials" {
  count                   = local.create ? 1 : 0
  name                    = "${var.project}/rds/credentials"
  description             = "RDS Postgres credentials for ${var.project}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "credentials" {
  count     = local.create ? 1 : 0
  secret_id = aws_secretsmanager_secret.credentials[0].id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master[0].result
    engine   = "postgres"
    host     = aws_db_instance.this[0].address
    port     = aws_db_instance.this[0].port
    dbname   = aws_db_instance.this[0].db_name
    dsn = format(
      "postgresql://%s:%s@%s:%d/%s",
      var.master_username,
      random_password.master[0].result,
      aws_db_instance.this[0].address,
      aws_db_instance.this[0].port,
      aws_db_instance.this[0].db_name,
    )
  })
}
