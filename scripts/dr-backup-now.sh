#!/usr/bin/env bash
#
# dr-backup-now.sh — Take an on-demand backup of the PRIMARY database and copy it
# cross-region to the DR vault, producing a fresh recovery point that reflects the
# current primary. Use after recreating/failing-back the primary, or any time you
# want an up-to-date DR copy without waiting for the daily schedule.
#
# NOTE: the backup captures whatever is in the primary RIGHT NOW. If you just
# recreated an empty primary, seed it first (run the db-migrate Job) so the DR
# copy isn't empty.
#
# Required:
#   BACKUP_ROLE_ARN   AWS Backup service role (terraform output backup_role_arn)
# Optional (defaults):
#   PROJECT=fincorp  PRIMARY_REGION=eu-west-1  DR_REGION=eu-west-2
#   DB_ID=${PROJECT}-db  PRIMARY_VAULT=${PROJECT}-backup-primary  DR_VAULT=${PROJECT}-backup-dr
#
set -euo pipefail

PROJECT="${PROJECT:-fincorp}"
PRIMARY_REGION="${PRIMARY_REGION:-eu-west-1}"
DR_REGION="${DR_REGION:-eu-west-2}"
DB_ID="${DB_ID:-${PROJECT}-db}"
PRIMARY_VAULT="${PRIMARY_VAULT:-${PROJECT}-backup-primary}"
DR_VAULT="${DR_VAULT:-${PROJECT}-backup-dr}"
: "${BACKUP_ROLE_ARN:?Set BACKUP_ROLE_ARN (terraform output backup_role_arn)}"

log() { printf '\033[1;35m[dr-backup]\033[0m %s\n' "$*"; }

DB_ARN=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --region "$PRIMARY_REGION" --query 'DBInstances[0].DBInstanceArn' --output text)
DR_VAULT_ARN="arn:aws:backup:${DR_REGION}:$(aws sts get-caller-identity --query Account --output text):backup-vault:${DR_VAULT}"

log "Primary:      $DB_ID ($DB_ARN)"
log "Primary vault: $PRIMARY_VAULT ($PRIMARY_REGION)"
log "DR vault:      $DR_VAULT ($DR_REGION)"

# 1) On-demand backup of the primary into the primary vault.
log "Starting on-demand backup..."
BJOB=$(aws backup start-backup-job \
  --backup-vault-name "$PRIMARY_VAULT" \
  --resource-arn "$DB_ARN" \
  --iam-role-arn "$BACKUP_ROLE_ARN" \
  --region "$PRIMARY_REGION" \
  --query BackupJobId --output text)
log "Backup job: $BJOB"

# 2) Wait for the backup to complete.
while true; do
  S=$(aws backup describe-backup-job --backup-job-id "$BJOB" --region "$PRIMARY_REGION" --query State --output text)
  log "  backup state=$S"
  case "$S" in
    COMPLETED) break ;;
    ABORTED|FAILED|EXPIRED)
      MSG=$(aws backup describe-backup-job --backup-job-id "$BJOB" --region "$PRIMARY_REGION" --query StatusMessage --output text)
      echo "ERROR: backup $S — $MSG" >&2; exit 1 ;;
  esac
  sleep 20
done
RP_ARN=$(aws backup describe-backup-job --backup-job-id "$BJOB" --region "$PRIMARY_REGION" --query RecoveryPointArn --output text)
log "Recovery point (primary): $RP_ARN"

# 3) Copy it cross-region to the DR vault (on-demand backups aren't auto-copied
#    by the plan's copy_action — only scheduled ones are).
log "Starting cross-region copy to $DR_REGION..."
CJOB=$(aws backup start-copy-job \
  --recovery-point-arn "$RP_ARN" \
  --source-backup-vault-name "$PRIMARY_VAULT" \
  --destination-backup-vault-arn "$DR_VAULT_ARN" \
  --iam-role-arn "$BACKUP_ROLE_ARN" \
  --region "$PRIMARY_REGION" \
  --query CopyJobId --output text)
log "Copy job: $CJOB"

while true; do
  S=$(aws backup describe-copy-job --copy-job-id "$CJOB" --region "$PRIMARY_REGION" --query CopyJob.State --output text)
  log "  copy state=$S"
  case "$S" in
    COMPLETED) break ;;
    FAILED)
      MSG=$(aws backup describe-copy-job --copy-job-id "$CJOB" --region "$PRIMARY_REGION" --query CopyJob.StatusMessage --output text)
      echo "ERROR: copy $S — $MSG" >&2; exit 1 ;;
  esac
  sleep 20
done

log "DONE — a fresh recovery point for the current primary is now in $DR_VAULT ($DR_REGION)."
log "The next dr-restore.sh run will use this newest point."
