output "repository_urls" {
  description = "Map of service name -> ECR repo URL (consumed by ecs-services in Step 9)."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  description = "Map of service name -> ECR repo ARN (consumed by IAM in Step 7)."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}

output "registry_id" {
  description = "AWS account ID hosting the repos - useful for `docker login`."
  value       = values(aws_ecr_repository.this)[0].registry_id
}
