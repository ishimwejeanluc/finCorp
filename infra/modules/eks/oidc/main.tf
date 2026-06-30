terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

# Fetch the OIDC issuer's TLS cert so we can pin its thumbprint into IAM.
data "tls_certificate" "this" {
  url = var.cluster_oidc_issuer
}

# Register the cluster's OIDC issuer as an IAM identity provider.
# Foundation for IRSA - K8s ServiceAccounts can now assume IAM roles via
# AssumeRoleWithWebIdentity, using tokens signed by the cluster.
resource "aws_iam_openid_connect_provider" "this" {
  url             = var.cluster_oidc_issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.this.certificates[0].sha1_fingerprint]
}
