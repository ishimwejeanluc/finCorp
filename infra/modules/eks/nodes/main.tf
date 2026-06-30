terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

# Node IAM role - what the EC2 instances themselves assume.
resource "aws_iam_role" "node" {
  name = "${var.project}-eks-node-${var.node_group_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.project}-eks-node-${var.node_group_name}" }
}

# Three policies every EKS worker node needs.
resource "aws_iam_role_policy_attachment" "worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Lets the CloudWatch agent / Fluent Bit (installed by the cloudwatch-observability
# addon) push container logs and metrics to CloudWatch.
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# The managed node group itself.
resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = var.node_group_name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.instance_types
  ami_type       = var.ami_type
  capacity_type  = var.capacity_type
  disk_size      = var.disk_size_gb

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = { Name = "${var.project}-eks-node-${var.node_group_name}" }

  # Without explicit depends_on, the node group can race the policy attachments
  # and fail with "instances failed to join the cluster" on first apply.
  depends_on = [
    aws_iam_role_policy_attachment.worker,
    aws_iam_role_policy_attachment.cni,
    aws_iam_role_policy_attachment.ecr_read,
    aws_iam_role_policy_attachment.cloudwatch_agent,
  ]

  lifecycle {
    # desired_size moves under autoscaling pressure; don't fight it on every apply.
    ignore_changes = [scaling_config[0].desired_size]
  }
}
