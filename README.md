# FinCorp — Secure Software Supply Chain + Cross-Region DR

A 3-tier app (FastAPI backend, Express frontend, RDS Postgres, ElastiCache Redis)
running on **Amazon EKS**, with:

1. **A secure, auditable artifact pipeline** — AWS CodeArtifact proxies npm/pip,
   GitHub Actions builds and pushes **immutable** images to ECR, and the build
   **fails on High/Critical** vulnerabilities.
2. **Cross-region Disaster Recovery** — RDS in `eu-west-1`, AWS Backup daily
   snapshots copied to `eu-west-2`, with a scripted restore inside a 30-minute RTO.

> Built by forking the EKS lab and re-namespacing everything to `fincorp`
> (region, VPC CIDR, cluster, ECR repos, state key) so it coexists with the
> original `shopnow-eks` lab in one AWS account.

## At a glance

| | Primary `eu-west-1` | DR `eu-west-2` |
|---|---|---|
| Compute | EKS `fincorp` + node group | — |
| Data | RDS `fincorp-db` (CMK-encrypted) | restored `fincorp-db-restored` |
| Backup | vault `fincorp-backup-primary` | vault `fincorp-backup-dr` |
| Supply chain | CodeArtifact `fincorp`, ECR `fincorp/*` | — |

## Pipeline

```
push → OIDC → CodeArtifact login → build → Trivy (fail H/C) → push :<git-sha> → deploy to EKS
```
No static AWS keys. Tags are the Git commit SHA; ECR repos are `IMMUTABLE`.

## Documentation

| Doc | Topic |
|---|---|
| [docs/architecture.md](docs/architecture.md) | system overview + diagrams |
| [docs/00-deploy.md](docs/00-deploy.md) | end-to-end deploy guide |
| [docs/01-codeartifact.md](docs/01-codeartifact.md) | npm/pip proxy |
| [docs/02-pipeline.md](docs/02-pipeline.md) | GitHub Actions pipeline |
| [docs/03-ecr-immutability-scanning.md](docs/03-ecr-immutability-scanning.md) | immutable tags + scanning |
| [docs/04-dr-setup.md](docs/04-dr-setup.md) | AWS Backup cross-region setup |
| [docs/05-dr-runbook.md](docs/05-dr-runbook.md) | **live DR walkthrough** |
| [docs/ADR.md](docs/ADR.md) | decision record |
| [docs/fincorp-plan.md](docs/fincorp-plan.md) | original design plan |

## Layout

```
backend/ frontend/        app + CodeArtifact-aware Dockerfiles
k8s/                      manifests (namespace: fincorp)
.github/workflows/        build-and-push.yml, dr-restore.yml
scripts/dr-restore.sh     DR failover automation
infra/live-fincorp/       the Terraform stack
infra/modules/            network ecr elasticache rds eks/* codeartifact github-oidc backup
```

## Quick start
See [docs/00-deploy.md](docs/00-deploy.md). TL;DR:
```bash
cd infra/live-fincorp && terraform init && terraform apply
# set GitHub repo Variables from terraform outputs, then push to main
```
