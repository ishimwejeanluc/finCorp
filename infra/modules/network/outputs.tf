output "vpc_id" {
  description = "VPC ID - consumed by SGs, RDS, ElastiCache, ALB, and ECS services."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR - used in security group rules that target the whole VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs - for the internet-facing ALB (Step 8)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs - for ECS tasks, RDS, ElastiCache, internal ALB."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs - informational."
  value       = [aws_nat_gateway.this.id]
}

output "availability_zones" {
  description = "AZs the subnets are spread across."
  value       = local.azs
}
