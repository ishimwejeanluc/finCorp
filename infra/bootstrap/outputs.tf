output "state_bucket_name" {
  description = "Name of the S3 bucket holding remote Terraform state. Plug into each env's backend.tf."
  value       = aws_s3_bucket.tfstate.id
}

output "state_lock_table_name" {
  description = "DynamoDB table used by Terraform for state locking."
  value       = aws_dynamodb_table.tfstate_lock.id
}

output "aws_region" {
  description = "Region the state bucket and lock table live in."
  value       = "eu-west-1"
}
