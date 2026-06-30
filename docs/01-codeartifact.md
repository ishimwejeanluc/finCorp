# 1 — AWS CodeArtifact (npm + pip upstream proxy)

## Why

FinCorp requires an **auditable** supply chain. Pulling dependencies straight from
public npm/PyPI gives no central record and no kill-switch. CodeArtifact sits
**in front of** the public registries: every package version a build consumes is
proxied, cached, and attributable, and the org can cut off a poisoned upstream
without breaking builds.

## What Terraform creates

`infra/modules/codeartifact`:

| Resource | Value |
|---|---|
| Domain | `fincorp` |
| Repository `npm-proxy` | external connection `public:npmjs` |
| Repository `pypi-proxy` | external connection `public:pypi` |
| Repo permission policy | read access for the CI role |

```hcl
module "codeartifact" {
  source       = "../modules/codeartifact"
  project      = var.project              # → domain "fincorp"
  ci_role_arns = [module.github_oidc.ci_role_arn]
}
```

## How a build authenticates

No static credentials. The GitHub Actions runner already holds short-lived AWS
creds (via OIDC), then:

```bash
TOKEN=$(aws codeartifact get-authorization-token \
  --domain fincorp --domain-owner <ACCOUNT_ID> \
  --region eu-west-1 --query authorizationToken --output text)

HOST=fincorp-<ACCOUNT_ID>.d.codeartifact.eu-west-1.amazonaws.com
# npm  → https://$HOST/npm/npm-proxy/
# pip  → https://aws:$TOKEN@$HOST/pypi/pypi-proxy/simple/
```

The token is valid for 12 hours and is passed into `docker build` as a **BuildKit
secret** (`--mount=type=secret,id=ca_token`) so it never lands in an image layer.
See [02-pipeline.md](02-pipeline.md) for how the Dockerfiles consume it.

## Verify it works

```bash
# List packages CodeArtifact has cached from upstream after a build
aws codeartifact list-packages --domain fincorp \
  --repository pypi-proxy --region eu-west-1

aws codeartifact list-packages --domain fincorp \
  --repository npm-proxy --region eu-west-1
```

Cached packages appearing here confirm the build pulled **through** the proxy, not
directly from the public internet.
