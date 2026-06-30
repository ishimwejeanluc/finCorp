#!/usr/bin/env bash
#
# dr-restore.sh — Restore the FinCorp database in the DR region (eu-west-2)
# from the latest AWS Backup cross-region recovery point.
#
# Use during a simulated/real primary-region failure. Designed to complete well
# within the 30-minute RTO for a small instance.
#
# Required:
#   BACKUP_ROLE_ARN   AWS Backup service role (terraform output backup_role_arn)
# Optional (sensible defaults):
#   PROJECT           default: fincorp
#   DR_REGION         default: eu-west-2
#   DR_VAULT          default: ${PROJECT}-backup-dr
#   NEW_DB_ID         default: ${PROJECT}-db-restored
#   DB_SUBNET_GROUP   default: ${PROJECT}-dr-db-subnets
#
set -euo pipefail

PROJECT="${PROJECT:-fincorp}"
DR_REGION="${DR_REGION:-eu-west-2}"
DR_VAULT="${DR_VAULT:-${PROJECT}-backup-dr}"
NEW_DB_ID="${NEW_DB_ID:-${PROJECT}-db-restored}"
DB_SUBNET_GROUP="${DB_SUBNET_GROUP:-${PROJECT}-dr-db-subnets}"
: "${BACKUP_ROLE_ARN:?Set BACKUP_ROLE_ARN (terraform output backup_role_arn)}"

log() { printf '\033[1;36m[dr-restore]\033[0m %s\n' "$*"; }

START_EPOCH=$(date +%s)
log "Region:        $DR_REGION"
log "Vault:         $DR_VAULT"
log "New instance:  $NEW_DB_ID"

# 1) Latest RDS recovery point in the DR vault (already copied cross-region).
log "Finding latest RDS recovery point..."
RP_ARN=$(aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name "$DR_VAULT" --region "$DR_REGION" \
  --by-resource-type RDS \
  --query 'sort_by(RecoveryPoints, &CreationDate)[-1].RecoveryPointArn' \
  --output text)

if [[ -z "$RP_ARN" || "$RP_ARN" == "None" ]]; then
  echo "ERROR: no RDS recovery point found in $DR_VAULT ($DR_REGION)." >&2
  echo "       Has the daily backup + cross-region copy run yet?" >&2
  exit 1
fi
log "Recovery point: $RP_ARN"

# 2) Restore metadata from the recovery point; override identifier + subnet group.
log "Reading restore metadata..."
META=$(aws backup get-recovery-point-restore-metadata \
  --backup-vault-name "$DR_VAULT" --recovery-point-arn "$RP_ARN" \
  --region "$DR_REGION" --query RestoreMetadata --output json)

NEW_META=$(echo "$META" | jq \
  --arg id "$NEW_DB_ID" \
  --arg sg "$DB_SUBNET_GROUP" \
  '. + {"DBInstanceIdentifier": $id, "DBSubnetGroupName": $sg}')

# 3) Kick off the restore.
log "Starting restore job..."
JOB_ID=$(aws backup start-restore-job \
  --recovery-point-arn "$RP_ARN" \
  --iam-role-arn "$BACKUP_ROLE_ARN" \
  --resource-type RDS \
  --metadata "$NEW_META" \
  --region "$DR_REGION" \
  --query RestoreJobId --output text)
log "Restore job: $JOB_ID"

# 4) Poll to completion.
while true; do
  STATUS=$(aws backup describe-restore-job --restore-job-id "$JOB_ID" \
    --region "$DR_REGION" --query Status --output text)
  ELAPSED=$(( $(date +%s) - START_EPOCH ))
  log "  status=$STATUS  elapsed=${ELAPSED}s"
  case "$STATUS" in
    COMPLETED) break ;;
    ABORTED|FAILED)
      MSG=$(aws backup describe-restore-job --restore-job-id "$JOB_ID" \
        --region "$DR_REGION" --query StatusMessage --output text)
      echo "ERROR: restore $STATUS — $MSG" >&2
      exit 1 ;;
  esac
  sleep 20
done

# 5) Report the recovered endpoint.
ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$NEW_DB_ID" \
  --region "$DR_REGION" \
  --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "pending")
TOTAL=$(( $(date +%s) - START_EPOCH ))

log "RESTORE COMPLETE in ${TOTAL}s (RTO target: 1800s)"
log "Recovered instance: $NEW_DB_ID"
log "Endpoint:           $ENDPOINT (port 5432)"
log "Next: attach a security group / re-point the app, then validate row counts."
