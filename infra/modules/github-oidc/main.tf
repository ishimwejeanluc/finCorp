# GitHub Actions -> AWS via OIDC. No long-lived access keys anywhere:
# the workflow exchanges its short-lived GitHub OIDC token for temporary AWS
# credentials by assuming the role below. Every assume-role is logged in
# CloudTrail, which is the "auditable supply chain" requirement.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  oidc_url = "token.actions.githubusercontent.com"
}

# Fetch the OIDC provider's TLS thumbprint dynamically.
data "tls_certificate" "github" {
  url = "https://${local.oidc_url}/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://${local.oidc_url}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]

  tags = { Name = "${var.project}-github-oidc" }
}

# ---------- CI role ----------
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only this repo may assume the role.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_url}:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "ci" {
  name               = "${var.project}-gha-ci"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = { Name = "${var.project}-gha-ci" }
}

# ---------- Permissions ----------
data "aws_iam_policy_document" "ci" {
  # --- ECR: auth + push immutable images + read scan findings ---
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:StartImageScan",
    ]
    resources = var.ecr_repo_arns
  }

  # --- CodeArtifact: pull deps through the proxy ---
  statement {
    sid    = "CodeArtifact"
    effect = "Allow"
    actions = [
      "codeartifact:GetAuthorizationToken",
      "codeartifact:GetRepositoryEndpoint",
      "codeartifact:ReadFromRepository",
      "codeartifact:DescribeRepository",
      "codeartifact:ListPackages",
      "codeartifact:GetPackageVersionReadme",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "CodeArtifactBearerToken"
    effect    = "Allow"
    actions   = ["sts:GetServiceBearerToken"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "sts:AWSServiceName"
      values   = ["codeartifact.amazonaws.com"]
    }
  }

  # --- EKS: read cluster info for `update-kubeconfig` + deploy ---
  statement {
    sid       = "EksDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${data.aws_partition.current.partition}:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }

  # --- AWS Backup: drive the DR restore workflow ---
  statement {
    sid    = "BackupRestore"
    effect = "Allow"
    actions = [
      "backup:StartRestoreJob",
      "backup:DescribeRestoreJob",
      "backup:ListRecoveryPointsByBackupVault",
      "backup:DescribeRecoveryPoint",
      "backup:DescribeBackupVault",
      "backup:GetRecoveryPointRestoreMetadata",
      "rds:DescribeDBInstances",
      "rds:DescribeDBSnapshots",
    ]
    resources = ["*"]
  }

  # Allow handing the AWS Backup service role to the restore job.
  statement {
    sid       = "PassBackupRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-backup-*"]
  }

  # Idempotent DR restore: delete a prior restored instance so the drill can
  # re-run (REPLACE / unhealthy-state recovery). Scoped to the RESTORED name
  # pattern only — the primary '${var.project}-db' is deliberately NOT matched,
  # so CI can never delete the production database.
  statement {
    sid       = "RdsDeleteRestoredOnly"
    effect    = "Allow"
    actions   = ["rds:DeleteDBInstance"]
    resources = ["arn:${data.aws_partition.current.partition}:rds:*:${data.aws_caller_identity.current.account_id}:db:${var.project}-db-restored*"]
  }

  # Read the app credential secrets so the pipeline can build the K8s Secret
  # (deploy) and rebuild the DSN on failover (DR re-point).
  statement {
    sid     = "ReadAppSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:${var.project}/rds/credentials-*",
      "arn:${data.aws_partition.current.partition}:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:${var.project}/redis/credentials-*",
    ]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "${var.project}-gha-ci"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}
