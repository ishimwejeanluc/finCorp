# 4 — Disaster Recovery Setup (AWS Backup, cross-region)

Module: `infra/modules/backup` · Primary `eu-west-1` → DR `eu-west-2`

## What gets created

| Resource | Region | Purpose |
|---|---|---|
| KMS CMK (primary) | eu-west-1 | encrypts the primary vault |
| KMS CMK (dr) | eu-west-2 | encrypts the DR vault |
| Backup vault `fincorp-backup-primary` | eu-west-1 | holds daily recovery points |
| Backup vault `fincorp-backup-dr` | eu-west-2 | receives cross-region copies |
| Backup plan `fincorp-daily-dr` | eu-west-1 | daily rule + `copy_action` to DR vault |
| Backup selection | — | matches resources tagged `Backup=fincorp` |
| IAM role `fincorp-backup-role` | — | AWS Backup service role (backup + restore) |
| DB subnet group `fincorp-dr-db-subnets` | eu-west-2 | restore target (in `infra/live-fincorp`) |

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
# 1. On-demand backup of the primary DB into the primary vault
aws backup start-backup-job \
  --backup-vault-name fincorp-backup-primary \
  --resource-arn "$(terraform output -raw rds_arn)" \
  --iam-role-arn "$(terraform output -raw backup_role_arn)" \
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
