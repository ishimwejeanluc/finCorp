# CodeArtifact: a private, audited proxy in front of public npm + PyPI.
# Builds pull dependencies *through* these repos instead of hitting the public
# internet directly, so every package version is cached, attributable, and
# scannable, and the org can sever a poisoned upstream without breaking builds.

data "aws_caller_identity" "current" {}

# ---------- Domain ----------
resource "aws_codeartifact_domain" "this" {
  domain = var.project
}

# ---------- npm proxy ----------
resource "aws_codeartifact_repository" "npm" {
  repository  = "npm-proxy"
  domain      = aws_codeartifact_domain.this.domain
  description = "npm packages proxied from the public npm registry"

  external_connections {
    external_connection_name = "public:npmjs"
  }
}

# ---------- PyPI proxy ----------
resource "aws_codeartifact_repository" "pypi" {
  repository  = "pypi-proxy"
  domain      = aws_codeartifact_domain.this.domain
  description = "Python packages proxied from PyPI"

  external_connections {
    external_connection_name = "public:pypi"
  }
}

# ---------- Read access for the CI role(s) ----------
data "aws_iam_policy_document" "repo_read" {
  count = length(var.ci_role_arns) > 0 ? 1 : 0

  statement {
    sid    = "AllowCIRead"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = var.ci_role_arns
    }
    actions = [
      "codeartifact:ReadFromRepository",
      "codeartifact:GetRepositoryEndpoint",
      "codeartifact:DescribeRepository",
      "codeartifact:GetPackageVersionReadme",
      "codeartifact:ListPackages",
    ]
    resources = ["*"]
  }
}

resource "aws_codeartifact_repository_permissions_policy" "npm" {
  count           = length(var.ci_role_arns) > 0 ? 1 : 0
  repository      = aws_codeartifact_repository.npm.repository
  domain          = aws_codeartifact_domain.this.domain
  policy_document = data.aws_iam_policy_document.repo_read[0].json
}

resource "aws_codeartifact_repository_permissions_policy" "pypi" {
  count           = length(var.ci_role_arns) > 0 ? 1 : 0
  repository      = aws_codeartifact_repository.pypi.repository
  domain          = aws_codeartifact_domain.this.domain
  policy_document = data.aws_iam_policy_document.repo_read[0].json
}
