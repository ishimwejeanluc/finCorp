# 4 — Disaster Recovery Setup (AWS Backup + ECR replication, cross-region)

Backup module: `infra/modules/backup`, in the **persistent layer**
(`infra/live-persistent`) · Primary `eu-west-1` → DR `eu-west-2`

> Layout: the DR-critical pieces below live in `infra/live-persistent` so they
> survive the drill; the app/DB live in `infra/live-primary` (and are rebuilt in
> `infra/live-dr` on failover). See [06-dr-rebuild-design.md](06-dr-rebuild-design.md)
> and [07-migration.md](07-migration.md).

## What gets created

| Resource | Layer / Region | Purpose |
|---|---|---|
| KMS CMK (primary) | persistent / eu-west-1 | encrypts the primary vault |
| KMS CMK (dr) | persistent / eu-west-2 | encrypts the DR vault |
| Backup vault `fincorp-backup-primary` | persistent / eu-west-1 | holds daily recovery points |
| Backup vault `fincorp-backup-dr` | persistent / eu-west-2 | receives cross-region copies |
| Backup plan `fincorp-daily-dr` | persistent / eu-west-1 | daily rule + `copy_action` to DR vault |
| Backup selection | persistent | matches resources tagged `Backup=fincorp` (the primary DB) |
| IAM role `fincorp-backup-role` | persistent | AWS Backup service role (backup + restore) |
| ECR replication (eu-west-1 → eu-west-2) | persistent | mirrors `fincorp/*` images to DR so the rebuilt stack can pull locally |
| DB subnet group `fincorp-db-subnets` | dr / eu-west-2 | restore landing (built by `module.stack` in `infra/live-dr`, `rds_mode=restore`) |

## Why a customer-managed KMS key matters

AWS Backup can only copy an **encrypted** recovery point to another region when the
source is encrypted with a **customer-managed** CMK (not the default `aws/rds`
key). The `rds` module therefore encrypts `fincorp-db` with its own CMK, and the
DR vault has its own CMK in eu-west-2. Without this, cross-region copy fails.

## The backup plan

```hcl
rule {
  schedule          = "cron(0 5 * * ? *)"   # daily 05:00 UTC
  target_vault_name = fincorp-backup-primary
  lifecycle { delete_after = 7 }
  copy_action {                              # the cross-region copy
    destination_vault_arn = <fincorp-backup-dr ARN>
    lifecycle { delete_after = 7 }
  }
}
```

## Pre-stage a recovery point for the demo

The scheduled rule runs daily; for a live walkthrough you usually can't wait. Take
an on-demand backup so a recovery point exists in the DR vault before you simulate
failure:

```bash
# Easiest: the helper does backup + cross-region copy end to end.
export BACKUP_ROLE_ARN="$(terraform -chdir=infra/live-persistent output -raw backup_role_arn)"
./scripts/dr-backup-now.sh

# Or manually — 1. on-demand backup of the primary DB into the primary vault
aws backup start-backup-job \
  --backup-vault-name fincorp-backup-primary \
  --resource-arn "$(terraform -chdir=infra/live-primary output -raw rds_arn)" \
  --iam-role-arn "$BACKUP_ROLE_ARN" \
  --region eu-west-1

# 2. Wait for it to COMPLETE, then confirm it copied to the DR vault
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name fincorp-backup-dr \
  --by-resource-type RDS --region eu-west-2
```

> Note: the daily rule's `copy_action` auto-copies scheduled backups to DR. An
> on-demand backup may need a manual `start-copy-job` to the DR vault if you want
> it copied immediately — the `list-recovery-points-by-backup-vault` check above
> tells you when a copy is present in eu-west-2.

When a recovery point shows up in `fincorp-backup-dr`, you are ready to run the
[DR runbook](05-dr-runbook.md).
