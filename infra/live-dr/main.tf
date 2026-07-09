# ============================================================================
# DR REGIONAL STACK — eu-west-2.
#
# The SAME module.stack as ../live-primary, parameterized for the DR region and
# rds_mode = "restore" (Terraform builds everything EXCEPT the DB instance).
#
# Applied ONLY at failover, by scripts/dr-restore.sh, which then:
#   1. restores the DB from the AWS Backup recovery point into this stack's VPC,
#   2. attaches this stack's RDS security group to it (local, same-VPC access),
#   3. deploys the app onto this stack's EKS cluster pointing at the local DB.
# ============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.70" }
    http = { source = "hashicorp/http", version = "~> 3.4" }
  }

  backend "s3" {
    bucket       = "fincorp-tfstate-497924967546"
    key          = "fincorp/dr.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "fincorp-dr"
    }
  }
}

data "terraform_remote_state" "persistent" {
  backend = "s3"
  config = {
    bucket = "fincorp-tfstate-497924967546"
    key    = "fincorp/persistent.tfstate"
    region = "eu-west-1"
  }
}

module "stack" {
  source = "../modules/stack"

  project            = var.project
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  rds_mode           = "restore"
  cluster_version    = var.cluster_version
  node_instance_type = var.node_instance_type
  node_desired_size  = var.node_desired_size
  ci_role_arn        = data.terraform_remote_state.persistent.outputs.gha_ci_role_arn
}
