# Regional application + data stack: VPC, EKS (cluster/nodes/addons/oidc), RDS,
# the AWS Load Balancer Controller IRSA, and the data-tier ingress rules.
# Region-agnostic — the same code stands the stack up in eu-west-1
# (primary, rds_mode="create") or eu-west-2 (DR, rds_mode="restore").

terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.70" }
    http = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

data "aws_caller_identity" "current" {}

# ---------- Network (VPC + subnets + NAT + VPC endpoints) ----------

module "network" {
  source = "../network"

  project  = var.project
  vpc_cidr = var.vpc_cidr
  az_count = var.az_count
}

# ---------- Data layer: RDS Postgres ----------
# create  -> fresh DB (primary). restore -> subnet group + SG only (DR landing).

module "rds" {
  source = "../rds"

  project            = var.project
  rds_mode           = var.rds_mode
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
}

# ---------- EKS ----------

module "eks_cluster" {
  source = "../eks/cluster"

  project            = var.project
  cluster_version    = var.cluster_version
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
}

module "eks_nodes" {
  source = "../eks/nodes"

  project            = var.project
  cluster_name       = module.eks_cluster.cluster_name
  private_subnet_ids = module.network.private_subnet_ids
  instance_types     = [var.node_instance_type]
  desired_size       = var.node_desired_size
}

module "eks_addons" {
  source = "../eks/addons"

  cluster_name   = module.eks_cluster.cluster_name
  node_group_arn = module.eks_nodes.node_group_arn
}

module "eks_oidc" {
  source              = "../eks/oidc"
  cluster_oidc_issuer = module.eks_cluster.oidc_issuer
}

# Let the CI role drive kubectl against this cluster (deploy / DR re-point).
resource "aws_eks_access_entry" "ci" {
  cluster_name  = module.eks_cluster.cluster_name
  principal_arn = var.ci_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "ci_admin" {
  cluster_name  = module.eks_cluster.cluster_name
  principal_arn = var.ci_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.ci]
}

# ---------- Data tier ingress from the cluster SG (local, same-VPC) ----------

resource "aws_security_group_rule" "rds_from_cluster" {
  type                     = "ingress"
  security_group_id        = module.rds.security_group_id
  source_security_group_id = module.eks_cluster.cluster_security_group_id
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  description              = "Postgres from EKS cluster SG"
}

# ---------- AWS Load Balancer Controller IRSA + policy ----------

data "http" "lb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.2/docs/install/iam_policy.json"
}

locals {
  upstream_lb_policy_statements = jsondecode(data.http.lb_controller_policy.response_body).Statement

  lb_controller_extra_statements = [
    {
      Sid    = "EC2DescribeForDiscovery"
      Effect = "Allow"
      Action = [
        "ec2:DescribeRouteTables",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeVpcPeeringConnections",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeInstances",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeTags",
        "ec2:DescribeAccountAttributes",
        "ec2:DescribeAddresses",
        "ec2:DescribeVpcAttribute",
      ]
      Resource = "*"
    },
    {
      Sid    = "ELBListenerAttributes"
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:DescribeListenerAttributes",
        "elasticloadbalancing:ModifyListenerAttributes",
      ]
      Resource = "*"
    },
  ]
}

resource "aws_iam_policy" "lb_controller" {
  name        = "${var.project}-lb-controller"
  description = "AWS Load Balancer Controller permissions (upstream v2.8.2 + extras)"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.upstream_lb_policy_statements, local.lb_controller_extra_statements)
  })
}

resource "aws_iam_role" "lb_controller" {
  name = "${var.project}-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = module.eks_oidc.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${module.eks_oidc.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${module.eks_oidc.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Name = "${var.project}-lb-controller" }
}

resource "aws_iam_role_policy_attachment" "lb_controller_irsa" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# ---------- Subnet tags for LB Controller auto-discovery ----------

locals {
  all_subnet_ids = concat(module.network.public_subnet_ids, module.network.private_subnet_ids)
}

resource "aws_ec2_tag" "public_subnet_elb_role" {
  count       = length(module.network.public_subnet_ids)
  resource_id = module.network.public_subnet_ids[count.index]
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "private_subnet_internal_elb_role" {
  count       = length(module.network.private_subnet_ids)
  resource_id = module.network.private_subnet_ids[count.index]
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

resource "aws_ec2_tag" "subnet_cluster_owner" {
  count       = length(local.all_subnet_ids)
  resource_id = local.all_subnet_ids[count.index]
  key         = "kubernetes.io/cluster/${module.eks_cluster.cluster_name}"
  value       = "shared"
}
