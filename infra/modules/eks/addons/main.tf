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

# NOTE: the amazon-cloudwatch-observability addon (CloudWatch agent + Fluent Bit +
# Container Insights log groups + Application Signals) was removed to keep the lab
# lean and speed up apply/destroy. Only the three core addons above are installed;
# container stdout is still viewable via `kubectl logs`.
