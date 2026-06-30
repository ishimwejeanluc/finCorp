locals {
  name = "${var.project}-redis"
}

# Redis AUTH tokens: 16–128 printable ASCII, no spaces, limited special chars.
resource "random_password" "auth" {
  length           = 48
  special          = true
  override_special = "!&#$^<>-"
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name}-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "${local.name}-subnets" }
}

# Empty-ingress SG; security module adds the backend->redis rule.
resource "aws_security_group" "this" {
  name        = "${local.name}-sg"
  description = "Redis - ingress added by security module"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-sg" }
}

resource "aws_elasticache_parameter_group" "this" {
  name        = "${local.name}-params"
  family      = "redis7"
  description = "Custom Redis 7 params for ${var.project}"

  # Disable risky commands. FLUSHALL/FLUSHDB by name; rename to "" makes them unrunnable.
  # (Commented because the rename-command param requires careful coordination; uncomment if needed.)
  # parameter { name = "rename-command-flushall" value = "" }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.name
  description          = "${var.project} Redis"

  engine         = "redis"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  num_cache_clusters         = var.num_cache_clusters
  automatic_failover_enabled = var.num_cache_clusters > 1
  multi_az_enabled           = var.num_cache_clusters > 1

  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.this.id]
  parameter_group_name = aws_elasticache_parameter_group.this.name

  # Encryption + AUTH go together. AWS rejects auth_token without transit_encryption.
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  auth_token                 = random_password.auth.result
  auth_token_update_strategy = "ROTATE"

  snapshot_retention_limit = var.snapshot_retention_days
  snapshot_window          = "03:00-04:00"
  maintenance_window       = "mon:05:00-mon:06:00"

  apply_immediately = false

  tags = { Name = local.name }

  lifecycle {
    ignore_changes = [engine_version]
  }
}

# Secrets Manager - full rediss:// URL plus raw token.
resource "aws_secretsmanager_secret" "credentials" {
  name                    = "${var.project}/redis/credentials"
  description             = "Redis AUTH token and connection URL for ${var.project}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "credentials" {
  secret_id = aws_secretsmanager_secret.credentials.id
  secret_string = jsonencode({
    auth_token = random_password.auth.result
    host       = aws_elasticache_replication_group.this.primary_endpoint_address
    port       = aws_elasticache_replication_group.this.port
    # rediss:// = Redis over TLS. The `default` username + AUTH is the v6+ pattern.
    url = format(
      "rediss://default:%s@%s:%d/0",
      random_password.auth.result,
      aws_elasticache_replication_group.this.primary_endpoint_address,
      aws_elasticache_replication_group.this.port,
    )
  })
}
