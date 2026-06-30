locals {
  name = "${var.project}-db"
}

# ---------- Generated master password ----------
# Excludes characters that confuse DSN parsers (@ : / ?).
resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#%^*-_=+"
}

# ---------- Customer-managed KMS key ----------
# A CMK (not the default aws/rds key) is REQUIRED for AWS Backup to copy the
# encrypted recovery point to another region. This is the linchpin of the DR plan.
resource "aws_kms_key" "db" {
  description             = "CMK for ${local.name} storage + snapshots (enables cross-region backup copy)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "${local.name}-kms" }
}

resource "aws_kms_alias" "db" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.db.key_id
}

# ---------- Subnet group ----------
resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "${local.name}-subnets" }
}

# ---------- Security group (no ingress; the live stack adds the rule from the EKS SG) ----------
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

# ---------- Parameter group ----------
resource "aws_db_parameter_group" "this" {
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

# ---------- RDS Postgres instance (the DR-protected database) ----------
# deletion_protection = false and skip_final_snapshot = true on purpose: the DR
# simulation deletes this instance to mimic a region failure.
resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.db.arn

  db_name  = var.db_name
  username = var.master_username
  password = random_password.master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
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

# ---------- Secrets Manager ----------
resource "aws_secretsmanager_secret" "credentials" {
  name                    = "${var.project}/rds/credentials"
  description             = "RDS Postgres credentials for ${var.project}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "credentials" {
  secret_id = aws_secretsmanager_secret.credentials.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    engine   = "postgres"
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = aws_db_instance.this.db_name
    dsn = format(
      "postgresql://%s:%s@%s:%d/%s",
      var.master_username,
      random_password.master.result,
      aws_db_instance.this.address,
      aws_db_instance.this.port,
      aws_db_instance.this.db_name,
    )
  })
}
