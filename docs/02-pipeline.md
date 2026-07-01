# 2 — CI/CD Pipeline (GitHub Actions)

Workflow: [`.github/workflows/build-and-push.yml`](../.github/workflows/build-and-push.yml)

## Triggers
- push to `main`
- push of a `v*` tag
- manual (`workflow_dispatch`)

## Stages

| # | Step | Purpose |
|---|------|---------|
| 1 | `configure-aws-credentials` (OIDC) | assume `fincorp-gha-ci` — **no static keys** |
| 2 | `amazon-ecr-login` | docker auth to ECR |
| 3 | Get CodeArtifact token + endpoints | proxy auth for npm/pip |
| 4 | `docker build --load` | build image; deps pulled through CodeArtifact (BuildKit secret) |
| 5 | **Trivy scan** | `severity HIGH,CRITICAL`, `exit-code 1` → **build fails on High/Critical** |
| 6 | Upload SARIF | findings appear in the repo Security tab (audit trail) |
| 7 | `docker push :<git-sha>` | push the immutable, scanned image |
| 8 | deploy job → `scripts/deploy-eks-k8s.sh --image-tag <sha>` | the script creates namespace + Secret on first run, then applies manifests pinned to `:<git-sha>` |

Backend and frontend build in parallel via a matrix. The Trivy gate runs
**before** the push, so a vulnerable image never reaches the registry.

The deploy job needs no manual bootstrap — it just calls **`scripts/deploy-eks-k8s.sh`**,
the single source of truth used identically in CI and locally. The script creates
the `fincorp` namespace and the `fincorp-db` Secret (from Secrets Manager) if
absent, renders the manifest placeholder tag to the commit SHA, and `kubectl apply`s
declaratively — so unchanged resources are untouched and only a new image SHA
triggers a rollout. The LB controller (Helm) is a one-time local setup
(`--ensure-lb-controller`), not run in CI.

## Required GitHub repo Variables

Settings → Secrets and variables → Actions → **Variables**:

| Variable | Source |
|---|---|
| `AWS_GHA_ROLE_ARN` | `terraform output gha_ci_role_arn` |
| `AWS_REGION` | `eu-west-1` |
| `AWS_ACCOUNT_ID` | your account id |
| `CODEARTIFACT_DOMAIN` | `fincorp` |
| `EKS_CLUSTER` | `fincorp` |
| `K8S_NAMESPACE` | `fincorp` |
| `BACKUP_ROLE_ARN` | `terraform output backup_role_arn` (for dr-restore) |

## How CodeArtifact reaches inside the Docker build

Both Dockerfiles accept a registry host as a build-arg and the token as a secret,
falling back to the public registry when absent (so local `docker build` still works):

- **backend** — `PIP_INDEX_HOST` + `--mount=type=secret,id=ca_token` → `pip wheel --index-url https://aws:$TOKEN@$HOST`
- **frontend** — `NPM_REGISTRY_HOST` + the same secret → `npm config set registry …` before `npm ci`

## Immutable artifacts

The image tag is the **full Git commit SHA**. A new commit → a new tag; the deploy
always pins one exact SHA (never `latest`). Combined with ECR tag immutability
(see [03-ecr-immutability-scanning.md](03-ecr-immutability-scanning.md)), every
image is a permanent, individually-addressable, tamper-proof artifact.
