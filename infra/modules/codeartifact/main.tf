# CodeArtifact: a private, audited proxy in front of public npm + PyPI.
# Builds pull dependencies *through* these repos instead of hitting the public
# internet directly, so every package version is cached, attributable, and
# scannable, and the org can sever a poisoned upstream without breaking builds.
#
# Access for the CI role is granted by its IDENTITY policy (see the github-oidc
# module: codeartifact:ReadFromRepository / GetRepositoryEndpoint / etc.), so no
# repository resource policy is needed here.

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
