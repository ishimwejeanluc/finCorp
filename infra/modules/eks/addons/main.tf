terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

# vpc-cni: the AWS CNI plugin that assigns pod IPs from VPC subnets.
# Install before coredns since coredns needs networking.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = var.cluster_name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Wait for nodes to exist - otherwise the daemonset has nowhere to schedule.
  depends_on = [var.node_group_arn]
}

# kube-proxy: in-cluster L4 routing for ClusterIP/NodePort Services.
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = var.cluster_name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [var.node_group_arn]
}

# coredns: in-cluster DNS. Default config schedules on EC2 nodes.
resource "aws_eks_addon" "coredns" {
  cluster_name                = var.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_addon.vpc_cni]
}

# Pre-create the four Container Insights log groups with retention. The addon
# below would auto-create them with "Never expire", which is the expensive default.
resource "aws_cloudwatch_log_group" "container_insights" {
  for_each          = toset(["application", "dataplane", "host", "performance"])
  name              = "/aws/containerinsights/${var.cluster_name}/${each.key}"
  retention_in_days = var.log_retention_days
}

# amazon-cloudwatch-observability: installs the CloudWatch agent + Fluent Bit
# DaemonSets that ship container stdout/stderr and node metrics to CloudWatch.
# Relies on the CloudWatchAgentServerPolicy attached to the node role.
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = var.cluster_name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    var.node_group_arn,
    aws_cloudwatch_log_group.container_insights,
  ]
}
