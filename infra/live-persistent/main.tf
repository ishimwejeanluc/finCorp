# ============================================================================
# PERSISTENT LAYER — survives the DR drill.
#
# Everything here is DR-critical or account-level and must NOT be destroyed when
# the primary region is torn down to simulate a region failure:
#   - AWS Backup vaults + recovery points (the whole point of DR)
#   - ECR repos + cross-region replication (so the rebuilt DR nodes can pull images)
#   - GitHub OIDC provider + CI role (account-global)
#   - CodeArtifact (build-time proxies)
#
# The regional app/data stacks live in ../live-primary and ../live-dr and are the
# only things simulate-failure destroys.
# ============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  backend "s3" {
    bucket       = "fincorp-tfstate-497924967546"
    key          = "fincorp/persistent.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Default provider = home region (eu-west-1).
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "fincorp-persistent"
    }
  }
}

# DR provider (eu-west-2) — cross-region AWS Backup vault + KMS.
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "fincorp-persistent-dr"
    }
  }
}

# ---------- ECR (immutable tags + scan-on-push) ----------

module "ecr" {
  source = "../modules/ecr"

  project      = var.project
  repositories = ["backend", "frontend"]
}

# Cross-region replication so the rebuilt DR stack (eu-west-2) can pull images
# locally after a full primary-region loss. Replication auto-creates the repos
# in the destination region and keeps them in sync.
resource "aws_ecr_replication_configuration" "this" {
  replication_configuration {
    rule {
      destination {
        region      = var.dr_region
        registry_id = data.aws_caller_identity.current.account_id
      }
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------- GitHub Actions OIDC + CI role ----------

module "github_oidc" {
  source = "../modules/github-oidc"

  project       = var.project
  github_repo   = var.github_repo
  ecr_repo_arns = values(module.ecr.repository_arns)
}

# ---------- CodeArtifact (npm + pip upstream proxies) ----------

module "codeartifact" {
  source = "../modules/codeartifact"

  project = var.project
}

# ---------- Cross-region Disaster Recovery (AWS Backup) ----------
# Selection is TAG-based (Backup=<project>), so there is no hard dependency on the
# regional DB — the primary stack tags its instance and the daily plan picks it up.

module "backup" {
  source = "../modules/backup"

  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  project          = var.project
  backup_tag_value = var.project
  schedule         = var.backup_schedule
  retention_days   = var.backup_retention_days
}
