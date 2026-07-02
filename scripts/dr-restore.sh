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
# REPLACE=1 forces a fresh restore even if the target already exists (delete first).
REPLACE="${REPLACE:-0}"
: "${BACKUP_ROLE_ARN:?Set BACKUP_ROLE_ARN (terraform output backup_role_arn)}"

log() { printf '\033[1;36m[dr-restore]\033[0m %s\n' "$*"; }

report_endpoint() {
  local ep
  ep=$(aws rds describe-db-instances --db-instance-identifier "$NEW_DB_ID" \
    --region "$DR_REGION" --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "pending")
  log "Recovered instance: $NEW_DB_ID"
  log "Endpoint:           $ep (port 5432)"
}

is_true() { [[ "${1:-}" == "1" || "${1:-}" == "true" || "${1:-}" == "TRUE" || "${1:-}" == "yes" ]]; }

delete_target() {
  log "Deleting existing '$NEW_DB_ID'..."
  aws rds delete-db-instance --db-instance-identifier "$NEW_DB_ID" \
    --skip-final-snapshot --delete-automated-backups --region "$DR_REGION" >/dev/null || true
  aws rds wait db-instance-deleted --db-instance-identifier "$NEW_DB_ID" --region "$DR_REGION" || true
}

START_EPOCH=$(date +%s)
log "Region:        $DR_REGION"
log "Vault:         $DR_VAULT"
log "New instance:  $NEW_DB_ID"

# 0) Idempotency: converge safely if the target instance already exists.
CUR=$(aws rds describe-db-instances --db-instance-identifier "$NEW_DB_ID" \
  --region "$DR_REGION" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)
if [[ -n "$CUR" && "$CUR" != "None" ]]; then
  log "Target '$NEW_DB_ID' already exists (status: $CUR)."
  if is_true "$REPLACE"; then
    log "REPLACE set — replacing it with a fresh restore."
    delete_target
  else
    case "$CUR" in
      available)
        log "Already restored — nothing to do (idempotent). Set REPLACE=1 to force a fresh restore."
        report_endpoint
        exit 0 ;;
      creating|modifying|backing-up|configuring-*|starting|maintenance|renaming|upgrading|storage-optimization|resetting-master-credentials)
        log "A restore is already in progress — waiting for it to become available..."
        aws rds wait db-instance-available --db-instance-identifier "$NEW_DB_ID" --region "$DR_REGION"
        log "Now available (idempotent)."
        report_endpoint
        exit 0 ;;
      *)
        log "Existing instance is in unhealthy state '$CUR' — recreating it."
        delete_target ;;
    esac
  fi
fi

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

# Clean the metadata AWS Backup returns before feeding it to start-restore-job.
# Drop fields that belong to the SOURCE region (eu-west-1) and don't exist in the
# DR region, so RDS uses DR-region defaults + our DR subnet group instead:
#   - DBSnapshotIdentifier : rejected (the snapshot comes from --recovery-point-arn)
#   - AvailabilityZone     : eu-west-1a doesn't exist in eu-west-2
#   - VpcSecurityGroupIds  : source-VPC SG IDs, invalid in the DR VPC
#   - DBParameterGroupName : fincorp-db-params only exists in eu-west-1
#   - OptionGroupName      : source-region option group
#   - InformationalOnly:* / aws:backup:* : read-only/internal, not valid inputs
# Then override identifier + subnet group (+ port) for the DR landing.
NEW_META=$(echo "$META" | jq \
  --arg id "$NEW_DB_ID" \
  --arg sg "$DB_SUBNET_GROUP" \
  '(del(.DBSnapshotIdentifier, .AvailabilityZone, .VpcSecurityGroupIds, .DBParameterGroupName, .OptionGroupName, .DBName)
    | with_entries(select((.key | startswith("InformationalOnly:")) or (.key | startswith("aws:backup:")) | not)))
   + {"DBInstanceIdentifier": $id, "DBSubnetGroupName": $sg, "Port": "5432"}')

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
TOTAL=$(( $(date +%s) - START_EPOCH ))
log "RESTORE COMPLETE in ${TOTAL}s (RTO target: 1800s)"
report_endpoint
log "Next: attach a security group / re-point the app, then validate row counts."
