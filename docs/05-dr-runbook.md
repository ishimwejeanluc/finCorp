# 5 — DR Runbook (Live Walkthrough)

**Goal:** restore `fincorp-db` in **eu-west-2** within **30 minutes (RTO)** after a
simulated `eu-west-1` failure.

> The 30-minute clock is **restore time**, not copy time. The cross-region copy
> runs daily, *ahead* of any incident — so a recovery point already exists in DR
> when failure strikes. See [04-dr-setup.md](04-dr-setup.md) to pre-stage one.

---

## 0. Pre-checks (before the demo)

```bash
cd infra/live-fincorp
terraform output backup_role_arn          # used by the restore
terraform output backup_vault_dr           # fincorp-backup-dr
# Confirm a recovery point exists in the DR region:
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name fincorp-backup-dr \
  --by-resource-type RDS --region eu-west-2 \
  --query 'RecoveryPoints[].{arn:RecoveryPointArn,created:CreationDate,status:Status}'
```
✅ At least one `COMPLETED` recovery point in `fincorp-backup-dr`.

## 1. Simulate the region failure  ⏱️ start the clock

Delete the primary database (mimics losing eu-west-1). `deletion_protection` is
off and `skip_final_snapshot` is on, so this is a clean delete:

```bash
aws rds delete-db-instance \
  --db-instance-identifier fincorp-db \
  --skip-final-snapshot --delete-automated-backups \
  --region eu-west-1
```
Show in the console that `fincorp-db` is `deleting` / gone.

## 2. Recover in the DR region

**Option A — one click (recommended for the walkthrough):**
GitHub → Actions → **dr-restore** → *Run workflow* → keep
`new_db_identifier = fincorp-db-restored`.

**Option B — local CLI (same logic):**
```bash
export BACKUP_ROLE_ARN="$(cd infra/live-fincorp && terraform output -raw backup_role_arn)"
./scripts/dr-restore.sh
```

The script/workflow:
1. finds the latest RDS recovery point in `fincorp-backup-dr`,
2. reads its restore metadata, retargets it to `fincorp-db-restored` + the DR DB subnet group,
3. runs `start-restore-job`, polls to `COMPLETED`, prints the endpoint and elapsed time.

## 3. Validate  ⏱️ stop the clock

```bash
aws rds describe-db-instances \
  --db-instance-identifier fincorp-db-restored \
  --region eu-west-2 \
  --query 'DBInstances[0].{status:DBInstanceStatus,endpoint:Endpoint.Address}'
```
Then connect (Query Editor / psql via a bastion) and confirm the data is intact:
```sql
SELECT count(*) FROM <your_table>;
```
✅ Record the elapsed time from step 1 → here. For a `db.t3.micro` this is
typically **10–20 minutes**, inside the 30-minute RTO.

## 4. Re-point the app (automatic)
When run via the **dr-restore** workflow with `repoint_app = true` (the default),
the cutover is automatic: after the restore it reads the restored endpoint, reuses
the preserved master credentials from Secrets Manager, rewrites only the
`POSTGRES_DSN` in the `fincorp-db` Kubernetes Secret (keeping `REDIS_URL`), and
restarts the backend so it reconnects to the recovered database.

Untick `repoint_app` if the primary region/cluster is genuinely down (then you'd
fail traffic over per your wider DR plan instead). The equivalent manual steps:
```bash
NEW_HOST=$(aws rds describe-db-instances --db-instance-identifier fincorp-db-restored \
  --region eu-west-2 --query 'DBInstances[0].Endpoint.Address' --output text)
# rebuild the DSN with NEW_HOST, update the fincorp-db Secret, then:
kubectl -n fincorp rollout restart deployment/backend
```

---

## RTO / RPO summary

| Metric | Value | Driven by |
|---|---|---|
| **RPO** | ≤ 24 h | daily backup schedule (tighten the cron for a smaller RPO) |
| **RTO** | < 30 min | restore time of a small instance from an already-copied recovery point |

## Cleanup after the demo
```bash
aws rds delete-db-instance --db-instance-identifier fincorp-db-restored \
  --skip-final-snapshot --region eu-west-2
# Recreate the primary with: terraform apply (in infra/live-fincorp)
```
