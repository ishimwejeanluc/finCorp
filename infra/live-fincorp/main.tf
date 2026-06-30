terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.70" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    http   = { source = "hashicorp/http", version = "~> 3.4" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  # Remote state: reuse the account-global state bucket + lock table, but a
  # NEW key so the FinCorp lab never collides with shopnow-eks state.
  backend "s3" {
    bucket         = "shopnow-tfstate-497924967546"
    key            = "fincorp/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "shopnow-tfstate-lock"
    encrypt        = true
  }
}

# ---------- Providers ----------
# Default provider = primary region (eu-west-1).
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "fincorp"
    }
  }
}

# DR provider (eu-west-2) — used for the cross-region AWS Backup vault + KMS.
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "fincorp-dr"
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------- Network (own VPC at 10.20.0.0/16) ----------

module "network" {
  source = "../modules/network"

  project  = var.project
  vpc_cidr = var.vpc_cidr
  az_count = var.az_count
}

# ---------- ECR (Terraform owns the repos: IMMUTABLE tags + scan-on-push) ----------

module "ecr" {
  source = "../modules/ecr"

  project      = var.project
  repositories = ["backend", "frontend"]
}

# ---------- GitHub Actions OIDC + CI role ----------

module "github_oidc" {
  source = "../modules/github-oidc"

  project       = var.project
  github_repo   = var.github_repo
  cluster_name  = module.eks_cluster.cluster_name
  ecr_repo_arns = values(module.ecr.repository_arns)
  region        = var.aws_region
}

# ---------- CodeArtifact (npm + pip upstream proxies) ----------

module "codeartifact" {
  source = "../modules/codeartifact"

  project      = var.project
  ci_role_arns = [module.github_oidc.ci_role_arn]
}

# Let the CI role drive kubectl against the cluster (deploy step).
resource "aws_eks_access_entry" "ci" {
  cluster_name  = module.eks_cluster.cluster_name
  principal_arn = module.github_oidc.ci_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "ci_admin" {
  cluster_name  = module.eks_cluster.cluster_name
  principal_arn = module.github_oidc.ci_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.ci]
}

# ---------- Data layer: primary RDS Postgres (DR-protected) ----------

module "rds" {
  source = "../modules/rds"

  project            = var.project
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
}

module "elasticache" {
  source = "../modules/elasticache"

  project            = var.project
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
}

# ---------- Cross-region Disaster Recovery (AWS Backup) ----------

module "backup" {
  source = "../modules/backup"

  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  project          = var.project
  protected_db_arn = module.rds.db_arn
  backup_tag_value = module.rds.backup_tag_value
  schedule         = var.backup_schedule
  retention_days   = var.backup_retention_days
}

# ---------- DR restore target network (eu-west-2) ----------
# A restored RDS instance needs a DB subnet group in the DR region. This is a
# minimal private VPC (no NAT/IGW — the DB is reached via Query Editor/bastion)
# that exists purely so `start-restore-job` has a deterministic home.

data "aws_availability_zones" "dr" {
  provider = aws.dr
  state    = "available"
}

resource "aws_vpc" "dr" {
  provider             = aws.dr
  cidr_block           = "10.40.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-dr-vpc" }
}

resource "aws_subnet" "dr" {
  provider          = aws.dr
  count             = 2
  vpc_id            = aws_vpc.dr.id
  cidr_block        = cidrsubnet(aws_vpc.dr.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.dr.names[count.index]
  tags              = { Name = "${var.project}-dr-subnet-${count.index}" }
}

resource "aws_db_subnet_group" "dr" {
  provider   = aws.dr
  name       = "${var.project}-dr-db-subnets"
  subnet_ids = aws_subnet.dr[*].id
  tags       = { Name = "${var.project}-dr-db-subnets" }
}

# ---------- EKS ----------

module "eks_cluster" {
  source = "../modules/eks/cluster"

  project            = var.project
  cluster_version    = var.cluster_version
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
}

module "eks_nodes" {
  source = "../modules/eks/nodes"

  project            = var.project
  cluster_name       = module.eks_cluster.cluster_name
  private_subnet_ids = module.network.private_subnet_ids
  instance_types     = [var.node_instance_type]
  desired_size       = var.node_desired_size
}

module "eks_addons" {
  source = "../modules/eks/addons"

  cluster_name   = module.eks_cluster.cluster_name
  node_group_arn = module.eks_nodes.node_group_arn
}

module "eks_oidc" {
  source              = "../modules/eks/oidc"
  cluster_oidc_issuer = module.eks_cluster.oidc_issuer
}

# ---------- Data tier ingress from the cluster SG ----------

resource "aws_security_group_rule" "rds_from_cluster" {
  type                     = "ingress"
  security_group_id        = module.rds.security_group_id
  source_security_group_id = module.eks_cluster.cluster_security_group_id
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  description              = "Postgres from EKS cluster SG"
}

resource "aws_security_group_rule" "redis_from_cluster" {
  type                     = "ingress"
  security_group_id        = module.elasticache.security_group_id
  source_security_group_id = module.eks_cluster.cluster_security_group_id
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  description              = "Redis from EKS cluster SG"
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
