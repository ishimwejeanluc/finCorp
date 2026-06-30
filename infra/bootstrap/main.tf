terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
  # Local state on purpose - this config creates the remote backend itself.
}

provider "aws" {
  region = "eu-west-1"
  default_tags {
    tags = { Project = "shopnow", ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "shopnow-tfstate-${data.aws_caller_identity.current.account_id}"
  table_name  = "shopnow-tfstate-lock"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption { enabled = true }
  lifecycle { prevent_destroy = true }
}
