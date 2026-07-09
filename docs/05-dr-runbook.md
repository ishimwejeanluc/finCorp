# 5 — DR Runbook (Live Walkthrough)

**Model:** full-region rebuild. On a simulated loss of **eu-west-1**, Terraform
re-creates the identical stack in **eu-west-2** and the database is restored **into
that same VPC**, so the rebuilt app and the restored DB sit together and connect
locally — no cross-region reach, no peering.

> The cross-region backup copy + ECR image replication run **ahead** of any
> incident, so a recovery point and the images already exist in eu-west-2 when
> failure strikes. See [04-dr-setup.md](04-dr-setup.md) to pre-stage them.

---

## 0. Pre-checks (before the demo)

```bash
# Backup service role (persistent layer) + confirm a DR recovery point exists.
terraform -chdir=infra/live-persistent output -raw backup_role_arn
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name fincorp-backup-dr \
  --by-resource-type RDS --region eu-west-2 \
  --query 'RecoveryPoints[].{arn:RecoveryPointArn,created:CreationDate,status:Status}'

# Confirm images are replicated to the DR region.
aws ecr describe-images --repository-name fincorp/backend --region eu-west-2 \
  --query 'imageDetails[].imageTags' --output text
```
✅ At least one `COMPLETED` recovery point in `fincorp-backup-dr` **and** images
present in the eu-west-2 ECR.

## 1. Simulate the FULL region failure  ⏱️ start the clock

Destroy the **entire** primary stack (app + EKS + Redis + RDS + VPC). The
persistent layer (backups, ECR, OIDC) and the state bucket are separate and are
left intact.

```bash
export BACKUP_ROLE_ARN="$(terraform -chdir=infra/live-persistent output -raw backup_role_arn)"
./scripts/dr-simulate-failure.sh          # asks you to type the project name
# add --yes to skip the prompt in automation
```
The script refuses to run unless a recovery point exists in eu-west-2, then runs
`terraform -chdir=infra/live-primary destroy`.

## 2. Recover in the DR region

**Option A — one click:** GitHub → Actions → **dr-restore** → *Run workflow*
(keep `rebuild_infra = true`, `deploy_app = true`).

**Option B — local CLI (same logic):**
```bash
export BACKUP_ROLE_ARN="$(terraform -chdir=infra/live-persistent output -raw backup_role_arn)"
./scripts/dr-restore.sh
```

`dr-restore.sh` runs the whole recovery in order:
1. `terraform apply infra/live-dr` — rebuilds VPC, EKS, Redis, and the RDS landing
   (subnet group + SG) in eu-west-2,
2. restores the DB from the latest DR recovery point **into that VPC's subnet group**,
3. attaches the DR RDS security group + resets the master password to a fresh value,
4. writes `fincorp/rds/credentials` in eu-west-2,
5. deploys the app onto the DR cluster (`deploy-eks-k8s.sh`), pulling the
   **replicated** images from the eu-west-2 ECR and pointing at the **local** DB.

## 3. Validate  ⏱️ stop the clock

```bash
# DB is up and local to the DR VPC:
aws rds describe-db-instances --db-instance-identifier fincorp-db-restored \
  --region eu-west-2 --query 'DBInstances[0].{status:DBInstanceStatus,endpoint:Endpoint.Address}'

# App is running on the DR cluster:
aws eks update-kubeconfig --name fincorp --region eu-west-2
kubectl -n fincorp get pods,svc,ingress
kubectl -n fincorp get ingress          # ALB hostname to hit
```
✅ Record elapsed time from step 1 → here.

---

## RTO / RPO summary

| Metric | Value | Driven by |
|---|---|---|
| **RPO** | ≤ 24 h | daily backup schedule (tighten the cron for a smaller RPO) |
| **RTO** | ~25–40 min | from-zero rebuild: EKS control plane (~10–15 min) + nodes/addons + LB controller + app rollout, in parallel with the DB restore |

> This is a **cold-standby (rebuild)** posture — a larger RTO than the previous
> DB-only failover, in exchange for the whole stack living in one region with no
> cross-region dependency. To shrink RTO, keep a minimal always-on node group in
> eu-west-2 (warm standby) at standing cost.

## 4. Fail back / clean up after the demo
```bash
# Tear the DR stack down + remove the restored DB:
terraform -chdir=infra/live-dr destroy
aws rds delete-db-instance --db-instance-identifier fincorp-db-restored \
  --skip-final-snapshot --region eu-west-2

# Rebuild the primary:
terraform -chdir=infra/live-primary apply
# then re-deploy the app + take a fresh backup (scripts/dr-backup-now.sh).
```
