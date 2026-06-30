# FinCorp — Architecture

Secure software supply chain + cross-region disaster recovery, on EKS, driven by
GitHub Actions and Terraform.

- **Primary region:** `eu-west-1` (Ireland)
- **DR region:** `eu-west-2` (London)
- **Project namespace:** `fincorp` (isolated from the `shopnow-eks` lab)

## Components

| Layer | Resource | Notes |
|---|---|---|
| Supply chain | CodeArtifact domain `fincorp` | `npm-proxy` → public npm, `pypi-proxy` → PyPI |
| Registry | ECR `fincorp/backend`, `fincorp/frontend` | `IMMUTABLE` tags + scan-on-push |
| CI/CD | GitHub Actions + OIDC role `fincorp-gha-ci` | no static AWS keys |
| Compute | EKS `fincorp` + managed node group | app behind ALB ingress |
| Data | RDS Postgres `fincorp-db` (eu-west-1) | CMK-encrypted, tagged `Backup=fincorp` |
| Cache | ElastiCache Redis | app-only, out of DR scope |
| DR | AWS Backup plan + vaults (both regions) | daily backup + cross-region copy |

## Supply-chain flow

```
GitHub push (main / tag)
   │ OIDC → assume fincorp-gha-ci (short-lived creds)
   ▼
GitHub Actions
   1. CodeArtifact login (npm + pip token)
   2. docker build  (deps pulled THROUGH CodeArtifact via BuildKit secret)
   3. Trivy scan    → FAIL if HIGH/CRITICAL  ← the security gate
   4. docker push   fincorp/<svc>:<git-sha>  ← unique + immutable tag
   5. kubectl set image (commit-pinned rollout to EKS)
```

## DR flow

```
eu-west-1                                  eu-west-2
─────────                                  ─────────
RDS fincorp-db  ──daily backup──▶ primary vault
                                       │ cross-region copy
                                       ▼
                                  DR vault  ──restore──▶ fincorp-db-restored
```

1. **Steady state** — AWS Backup takes a daily snapshot and copies it to the DR vault.
2. **Simulate failure** — delete the primary `fincorp-db`.
3. **Recover** — `dr-restore.yml` / `scripts/dr-restore.sh` restores from the DR vault's latest recovery point into the eu-west-2 DB subnet group.
4. **Validate** — connect and check data; capture timestamps to prove RTO < 30 min.

## Repo map

```
backend/ frontend/         app code + CodeArtifact-aware Dockerfiles
k8s/                       Kubernetes manifests (namespace: fincorp)
.github/workflows/         build-and-push.yml, dr-restore.yml
scripts/dr-restore.sh      DR failover automation
infra/
  bootstrap/               remote-state bucket + lock (shared, pre-existing)
  live-fincorp/            the stack (providers, wiring, DR network)
  modules/
    network/ ecr/ elasticache/ rds/ eks/*
    codeartifact/ github-oidc/ backup/   ← new for this lab
docs/                      this documentation set
```

See the per-topic docs: [CodeArtifact](01-codeartifact.md) ·
[Pipeline](02-pipeline.md) · [ECR immutability & scanning](03-ecr-immutability-scanning.md) ·
[DR setup](04-dr-setup.md) · [DR runbook](05-dr-runbook.md) · [ADR](ADR.md).
