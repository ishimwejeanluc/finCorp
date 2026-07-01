# FinCorp — Secure Software Supply Chain + Cross-Region DR

> **Lab:** Artifact Management & Disaster Recovery
> **Platform:** Amazon EKS (ECS removed) · **CI/CD:** GitHub Actions · **IaC:** Terraform
> **Primary region:** `eu-west-1` (Ireland) · **DR region:** `eu-west-2` (London)
> **Status:** PLAN — nothing implemented yet, pending approval.

---

## 1. Objectives (from the scenario)

1. **Secure, auditable artifact pipeline** that produces **immutable** artifacts:
   - AWS **CodeArtifact** as an upstream proxy for **npm** and **pip**.
   - GitHub Actions builds the app and pushes a Docker image to **Amazon ECR** with **Image Scanning** and **Tag Immutability** enabled.
   - **Constraint:** the build **fails on High/Critical** vulnerabilities.
2. **Cross-region Disaster Recovery**:
   - **RDS** database in `eu-west-1`.
   - **AWS Backup** daily snapshots **copied to `eu-west-2`** (cross-region copy).
   - **Simulate** a region failure by **deleting the primary DB**.
   - **Recover** by **restoring in `eu-west-2`** from the copied backup — within **30 minutes**.

---

## 2. Current repo → target repo

The app is **FastAPI backend (pip)** + **Express frontend (npm)** — both ecosystems present, ideal for CodeArtifact.

### Remove (ECS, Jenkins)
| Remove | Reason |
|---|---|
| `infra/live/` | ECS live stack — not used |
| `infra/modules/ecs/*` | Already `git rm`'d; finalize the deletion |
| `Jenkinsfile` + ECS docs | CI moved to GitHub Actions |

### Keep & repurpose
`infra/live-eks/` (→ renamed), `infra/modules/eks/*`, `infra/modules/shared/{network,ecr,elasticache}`, `k8s/`, `backend/`, `frontend/`.

---

## 3. Naming / isolation matrix

Separate lab, **same AWS account** as the k8s lab → everything moves to a new `fincorp` namespace.

| Concern | k8s lab (existing) | FinCorp lab (new) |
|---|---|---|
| Project slug | `shopnow-eks` | `fincorp` |
| Primary region | `eu-west-1` | `eu-west-1` |
| DR region | — | `eu-west-2` |
| TF state bucket | `shopnow-tfstate-497924967546` | **`fincorp-tfstate-<acct>`** (own bucket) |
| TF state **key** | `shopnow-eks/terraform.tfstate` | **`fincorp/terraform.tfstate`** |
| TF lock table | `shopnow-tfstate-lock` | **`fincorp-tfstate-lock`** |
| VPC CIDR | `10.1.0.0/16` | **`10.20.0.0/16`** |
| EKS cluster name | `shopnow-eks` | **`fincorp-eks`** |
| ECR repos | `shopnow/backend,frontend` | **`fincorp/backend,frontend`** |
| Live stack dir | `infra/live-eks/` | **`infra/live-fincorp/`** |

> `infra/bootstrap` creates a **FinCorp-owned** `fincorp-tfstate-<acct>` bucket + `fincorp-tfstate-lock` table (`prevent_destroy`), with key `fincorp/terraform.tfstate` — fully isolated from the shopnow-eks lab's state.

---

## 4. Target architecture

```
                 GitHub repo (push to main / version tag)
                          │  OIDC (no static AWS keys)
                          ▼
              ┌─────────────────────────────┐
              │   GitHub Actions runner       │
              │ 1 CodeArtifact login (npm/pip)│──▶ CodeArtifact domain "fincorp"
              │ 2 docker build (BuildKit)     │     ├─ npm-proxy  → public:npmjs
              │ 3 Trivy scan ──FAIL if H/C────│     └─ pypi-proxy → public:pypi
              │ 4 push :<git-sha> (immutable) │──▶ ECR fincorp/backend, fincorp/frontend
              │ 5 kubectl set image (deploy)  │     (scan-on-push ON, IMMUTABLE ON)
              └─────────────────────────────┘
                          │
                          ▼
        ┌──────────────── eu-west-1 (PRIMARY) ─────────────────┐
        │  EKS fincorp-eks ──┐                                  │
        │   backend/frontend  │── connects ──▶ RDS Postgres     │
        │   ALB ingress       │                (fincorp-db)     │
        │                     └── ElastiCache (app only)        │
        │  AWS Backup vault (daily plan) ──copy──┐              │
        └─────────────────────────────────────────┼────────────┘
                                                   ▼
        ┌──────────────── eu-west-2 (DR) ──────────────────────┐
        │  AWS Backup vault (KMS-encrypted) ◀── cross-region    │
        │  recovery points  ──restore──▶ fincorp-db-restored    │
        └───────────────────────────────────────────────────────┘
```

---

## 5. Terraform layout

`shared/` is gone — with ECS removed there's no shared-vs-ecs split, so modules are flat:

```
infra/
  modules/
    network/               (reuse)
    ecr/                   (reuse — already IMMUTABLE + scan_on_push ✔)
    elasticache/           (reuse, app-only, out of DR scope)
    rds/                   (reuse / adapt — DR-protected database)
    eks/{cluster,nodes,addons,oidc}/  (reuse)
    codeartifact/          ★ NEW — domain + npm-proxy + pypi-proxy
    github-oidc/           ★ NEW — OIDC provider + scoped CI role
    backup/                ★ NEW — vaults (both regions) + plan + selection + KMS
  live-fincorp/            ★ NEW (renamed from live-eks)
    main.tf  variables.tf  outputs.tf
```

**Providers in `live-fincorp/`:**
```hcl
provider "aws" { region = "eu-west-1" }                # default = primary
provider "aws" { alias = "dr"  region = "eu-west-2" }  # DR vault + KMS
```

---

## 6. Component designs

### 6.1 CodeArtifact (`modules/cicd/codeartifact`)
- `aws_codeartifact_domain "fincorp"`.
- Repo `npm-proxy` → `external_connections = "public:npmjs"`.
- Repo `pypi-proxy` → `external_connections = "public:pypi"`.
- Repository permission policy granting the CI role pull/read.
- Outputs: domain name + repo endpoints for the pipeline.

### 6.2 ECR — immutable artifacts (reuse `shared/ecr`)
- Repos `fincorp/backend`, `fincorp/frontend`.
- Already enforces **`image_tag_mutability = IMMUTABLE`** and **`scan_on_push = true`** → matches the constraint out of the box.

**Immutability guarantee — two halves, both required:**
1. **Every image change gets its own unique tag.** The pipeline tags **each build with the full Git commit SHA** (`:<git-sha>`). A new commit ⇒ a new SHA ⇒ a brand-new tag. No two distinct images ever share a tag, and the deploy always references one exact SHA (never `latest`).
2. **A tag, once pushed, can never change.** With `IMMUTABLE` set, ECR **rejects any attempt to re-push an existing tag** (`ImageTagAlreadyExistsException`). So a given tag is permanently bound to exactly one image digest — what you scanned is byte-for-byte what you deploy.

> Net effect: image `fincorp/backend:<sha>` is a permanent, tamper-proof, individually-addressable artifact. Re-running the pipeline on the same commit is a safe no-op (push is rejected); a code change forces a new tag. This is exactly the FinCorp "immutable, auditable artifact" requirement.

- Build-blocking vuln gate is **Trivy** in CI (below); ECR scan-on-push remains for continuous/audit visibility.

### 6.3 GitHub OIDC (`modules/cicd/github-oidc`)
- `aws_iam_openid_connect_provider` for `token.actions.githubusercontent.com`.
- IAM role `fincorp-gha-ci`, trust scoped to `sub = repo:<owner>/<repo>:ref:refs/heads/main` (+ tags).
- Permissions: ECR push + scan-read, CodeArtifact read + `sts:GetServiceBearerToken`, `eks:DescribeCluster`.
- Role added to the EKS **access entry** so CI can `kubectl apply`.
- **No long-lived AWS keys** — CloudTrail records every assume-role (the auditability requirement).

### 6.4 RDS (`modules/data/rds`) — standard `aws_db_instance` PostgreSQL
- Single instance; cleanest delete+restore story and fastest RTO; matches the literal "RDS database".
- Leaves the k8s lab's Aurora module untouched.
- `storage_encrypted = true` (CMK), `copy_tags_to_snapshot = true`, `deletion_protection = false` (so the simulation can delete it), tag `Backup = fincorp`.
- Credentials in Secrets Manager; app reads the DSN (wiring unchanged).

### 6.5 AWS Backup DR (`modules/dr/backup`)
- KMS CMK in **each** region (cross-region copy of encrypted backups needs a destination-region key).
- `aws_backup_vault` in `eu-west-1` + `aws_backup_vault` in `eu-west-2` (`provider = aws.dr`).
- `aws_backup_plan`: daily rule `cron(0 5 * * ? *)`, `copy_action { destination_vault_arn = <eu-west-2 vault> }`, retention 7 days.
- `aws_backup_selection` by tag `Backup = fincorp` → selects the RDS instance.
- For the demo: trigger an on-demand backup so a recovery point exists in `eu-west-2` before the simulation.

---

## 7. GitHub Actions pipeline

### `.github/workflows/build-and-push.yml` (push to `main` / version tag)
1. `actions/checkout`.
2. `aws-actions/configure-aws-credentials` via **OIDC** (assume `fincorp-gha-ci`).
3. **CodeArtifact login** → set npm registry + pip index-url (token in env).
4. `docker build` with **BuildKit secrets** passing the CodeArtifact token so `npm ci` / `pip install` inside the Dockerfiles pull **through the proxy**.
5. **Trivy scan** of the built image: `--severity HIGH,CRITICAL --exit-code 1` → **build fails on High/Critical**; SARIF uploaded to the Security tab for audit.
6. Tag `:<git-sha>` — **one unique tag per image change** — and push to ECR. Because the repo is `IMMUTABLE`, the push **fails loudly if that tag already exists**, so a tag can never be silently overwritten. ECR scan-on-push also runs.
7. **Deploy:** `aws eks update-kubeconfig` + `kubectl set image deploy/... =<repo>:<git-sha>` — commit-pinned, never `latest`.

### `.github/workflows/dr-restore.yml` (`workflow_dispatch`)
- Authenticates to `eu-west-2`, finds latest recovery point, runs `aws backup start-restore-job`, waits, prints the new endpoint — scripted recovery for the walkthrough.

### App / Dockerfile changes
- Frontend: `.npmrc` pointing at CodeArtifact, token via BuildKit secret mount.
- Backend: `pip.conf` / `--index-url` pointing at CodeArtifact, token via BuildKit secret mount.
- Small, contained edits to both Dockerfiles.

---

## 8. DR runbook (RTO strategy)

The 30-min RTO is **restore time**, not copy time — the cross-region copy runs daily ahead of any incident.

1. **Steady state:** daily backup + cross-region copy → recovery points already in `eu-west-2`.
2. **Simulate failure:** delete the primary RDS instance in `eu-west-1` (`deletion_protection=false`, skip final snapshot).
3. **Recover:** run `dr-restore.yml` (or `scripts/dr-restore.sh`) → `start-restore-job` from the `eu-west-2` vault → new `fincorp-db-restored`.
4. **Validate:** connect, run a row-count / seed-data check, capture start/end timestamps to prove RTO < 30 min.
5. Documented with **both** the console click-path and the CLI/automation path.

---

## 9. Documentation deliverables (`docs/`)
- `architecture.md` + diagram.
- `ADR.md` — decisions: standard RDS vs Aurora, Trivy vs ECR scan gate, OIDC vs static keys.
- `01-codeartifact.md`, `02-pipeline.md`, `03-ecr-immutability-scanning.md`.
- `04-dr-setup.md`, `05-dr-runbook.md` (the live-walkthrough script).
- Updated root `README.md`.

---

## 10. Execution phases (after approval)
1. **Cleanup & rename:** remove ECS stack/docs; rename `live-eks` → `live-fincorp`; re-key state; rename to `fincorp`, new CIDR, `eu-west-2` DR provider.
2. **Terraform:** CodeArtifact, GitHub OIDC, RDS instance, AWS Backup dual-region modules → wire into `live-fincorp`.
3. **App:** Dockerfile + CodeArtifact wiring.
4. **CI/CD:** GitHub Actions build/scan/push/deploy + DR restore workflow.
5. **Docs:** architecture, ADR, runbook.

---

## 11. Default decisions (baked into this plan)
| Decision | Default chosen | Note |
|---|---|---|
| DB engine | **Standard RDS Postgres** | Cleanest 30-min restore; matches "RDS database" |
| TF state | **Dedicated `fincorp-tfstate` bucket + lock** | Full isolation from shopnow-eks |
| Redis | **Keep (app-only)** | App needs it to run; excluded from DR scope |

> Flag any of these to change before implementation begins.
