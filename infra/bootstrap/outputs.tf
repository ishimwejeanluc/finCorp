output "state_bucket_name" {
  description = "Name of the S3 bucket holding remote Terraform state. Plug into each env's backend.tf."
  value       = aws_s3_bucket.tfstate.id
}

output "state_locking" {
  description = "State locking method (native S3 lockfile; no DynamoDB table)."
  value       = "use_lockfile (S3 native)"
}

output "aws_region" {
  description = "Region the state bucket and lock table live in."
  value       = "eu-west-1"
}
