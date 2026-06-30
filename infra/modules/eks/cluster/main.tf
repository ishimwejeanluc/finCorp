terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

# Cluster IAM role - assumed by the EKS control plane.
resource "aws_iam_role" "cluster" {
  name = "${var.project}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.project}-eks-cluster" }
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# The cluster itself.
resource "aws_eks_cluster" "this" {
  name     = var.project
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = concat(var.public_subnet_ids, var.private_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = var.enable_public_endpoint
  }

  # bootstrap_cluster_creator_admin_permissions grants admin to whoever runs terraform apply.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = var.enabled_log_types

  tags = { Name = var.project }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}
