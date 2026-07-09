# ============================================================================
# PRIMARY REGIONAL STACK — eu-west-1.
#
# The live application + data stack. This is the ONLY layer simulate-failure
# destroys (the persistent layer + DR recovery points survive). Recovery rebuilds
# the identical stack in eu-west-2 from ../live-dr (same module.stack).
# ============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.70" }
    http = { source = "hashicorp/http", version = "~> 3.4" }
  }

  backend "s3" {
    bucket       = "fincorp-tfstate-497924967546"
    key          = "fincorp/primary.tfstate"
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
      Stack     = "fincorp-primary"
    }
  }
}

# CI role lives in the persistent layer; read it for the EKS access entry.
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
  rds_mode           = "create"
  cluster_version    = var.cluster_version
  node_instance_type = var.node_instance_type
  node_desired_size  = var.node_desired_size
  ci_role_arn        = data.terraform_remote_state.persistent.outputs.gha_ci_role_arn
}
