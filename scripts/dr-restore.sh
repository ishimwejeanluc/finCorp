#!/usr/bin/env bash
#
# dr-restore.sh — FULL cross-region recovery in the DR region (eu-west-2).
#
# After a simulated full-region failure (scripts/dr-simulate-failure.sh destroyed
# the whole primary stack), this rebuilds everything in eu-west-2 and lands the
# database next to it, so the app and DB sit together and connect locally:
#
#   1. terraform apply  infra/live-dr   -> VPC, EKS, RDS landing (subnet
#                                          group + SG), LB controller IRSA.
#   2. start-restore-job                -> restore the DB from the latest DR
#                                          recovery point INTO that VPC's subnet group.
#   3. modify-db-instance               -> attach the DR RDS security group (local
#                                          access from the cluster) + reset the
#                                          master password to a fresh one.
#   4. write ${PROJECT}/rds/credentials in eu-west-2 with the new creds.
#   5. deploy-eks-k8s.sh                -> deploy the app onto the DR cluster,
#                                          pointing at the LOCAL restored DB.
#
# Required:
#   BACKUP_ROLE_ARN   AWS Backup service role (terraform -chdir=infra/live-persistent output -raw backup_role_arn)
# Optional (sensible defaults):
#   PROJECT           default: fincorp
#   DR_REGION         default: eu-west-2
#   DR_VAULT          default: ${PROJECT}-backup-dr
#   NEW_DB_ID         default: ${PROJECT}-db-restored
#   DR_DIR            default: infra/live-dr
#   REBUILD_INFRA     default: 1  (0 to skip terraform apply — infra already up)
#   DEPLOY_APP        default: 1  (0 to skip the kubectl deploy)
#   REPLACE           default: 0  (1 forces a fresh restore even if the DB exists)
#   NAMESPACE         default: ${PROJECT}
#
# Runs inline in the foreground and streams progress. It's a long job (~20-40 min);
# to survive a closed terminal, launch it under tmux/screen or with:
#   nohup bash scripts/dr-restore.sh >/tmp/dr-restore.log 2>&1 & tail -f /tmp/dr-restore.log
#
set -euo pipefail

# Ride out transient network/DNS blips on a flaky connection instead of aborting
# the whole run — the AWS CLI retries transient failures (timeouts, dropped
# connections, throttling) automatically. Override by exporting either var.
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"

PROJECT="${PROJECT:-fincorp}"
DR_REGION="${DR_REGION:-eu-west-2}"
DR_VAULT="${DR_VAULT:-${PROJECT}-backup-dr}"
NEW_DB_ID="${NEW_DB_ID:-${PROJECT}-db-restored}"
NAMESPACE="${NAMESPACE:-${PROJECT}}"
REPLACE="${REPLACE:-0}"
REBUILD_INFRA="${REBUILD_INFRA:-1}"
DEPLOY_APP="${DEPLOY_APP:-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DR_DIR="${DR_DIR:-${REPO_ROOT}/infra/live-dr}"
CRED_SECRET_ID="${CRED_SECRET_ID:-${PROJECT}/rds/credentials}"
: "${BACKUP_ROLE_ARN:?Set BACKUP_ROLE_ARN (terraform -chdir=infra/live-persistent output -raw backup_role_arn)}"

log()  { printf '\033[1;36m[dr-restore]\033[0m %s\n' "$*"; }
is_true() { [[ "${1:-}" == "1" || "${1:-}" == "true" || "${1:-}" == "TRUE" || "${1:-}" == "yes" ]]; }

START_EPOCH=$(date +%s)

# ---------- 1. Rebuild the DR stack (VPC, EKS, DB landing) ----------
if is_true "$REBUILD_INFRA"; then
  log "Rebuilding the DR stack in $DR_REGION (terraform apply $DR_DIR)..."
  terraform -chdir="$DR_DIR" init -input=false >/dev/null
  terraform -chdir="$DR_DIR" apply -auto-approve
else
  log "REBUILD_INFRA=0 — assuming the DR stack is already applied."
fi

# Read the landing details Terraform just produced.
DB_SUBNET_GROUP="$(terraform -chdir="$DR_DIR" output -raw rds_db_subnet_group_name)"
RDS_SG_ID="$(terraform -chdir="$DR_DIR" output -raw rds_security_group_id)"
CLUSTER="$(terraform -chdir="$DR_DIR" output -raw cluster_name)"
log "DB subnet group: $DB_SUBNET_GROUP"
log "RDS SG:          $RDS_SG_ID"
log "DR cluster:      $CLUSTER"

report_endpoint() {
  aws rds describe-db-instances --db-instance-identifier "$NEW_DB_ID" \
    --region "$DR_REGION" --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "pending"
}

delete_target() {
  log "Deleting existing '$NEW_DB_ID'..."
  aws rds delete-db-instance --db-instance-identifier "$NEW_DB_ID" \
    --skip-final-snapshot --delete-automated-backups --region "$DR_REGION" >/dev/null || true
  aws rds wait db-instance-deleted --db-instance-identifier "$NEW_DB_ID" --region "$DR_REGION" || true
}

# ---------- 2. Restore the DB into the DR VPC ----------
# Idempotency: converge safely if the target already exists.
CUR=$(aws rds describe-db-instances --db-instance-identifier "$NEW_DB_ID" \
  --region "$DR_REGION" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)

RESTORE_NEEDED=1
if [[ -n "$CUR" && "$CUR" != "None" ]]; then
  log "Target '$NEW_DB_ID' already exists (status: $CUR)."
  if is_true "$REPLACE"; then
    log "REPLACE set — replacing it with a fresh restore."
    delete_target
  else
    case "$CUR" in
      available)
        log "Already restored — skipping the restore step (idempotent)." ; RESTORE_NEEDED=0 ;;
      creating|modifying|backing-up|configuring-*|starting|maintenance|renaming|upgrading|storage-optimization|resetting-master-credentials)
        log "A restore is already in progress — waiting for it to become available..."
        aws rds wait db-instance-available --db-instance-identifier "$NEW_DB_ID" --region "$DR_REGION"
        RESTORE_NEEDED=0 ;;
      *)
        log "Existing instance is in unhealthy state '$CUR' — recreating it."
        delete_target ;;
    esac
  fi
fi

if [[ "$RESTORE_NEEDED" -eq 1 ]]; then
  log "Finding latest RDS recovery point in $DR_VAULT..."
  RP_ARN=$(aws backup list-recovery-points-by-backup-vault \
    --backup-vault-name "$DR_VAULT" --region "$DR_REGION" --by-resource-type RDS \
    --query 'sort_by(RecoveryPoints, &CreationDate)[-1].RecoveryPointArn' --output text)
  if [[ -z "$RP_ARN" || "$RP_ARN" == "None" ]]; then
    echo "ERROR: no RDS recovery point found in $DR_VAULT ($DR_REGION)." >&2
    exit 1
  fi
  log "Recovery point: $RP_ARN"

  log "Reading restore metadata..."
  META=$(aws backup get-recovery-point-restore-metadata \
    --backup-vault-name "$DR_VAULT" --recovery-point-arn "$RP_ARN" \
    --region "$DR_REGION" --query RestoreMetadata --output json)

  # Drop SOURCE-region fields that don't exist in the DR region, then override the
  # identifier + subnet group. The security group is attached AFTER the restore
  # (step 3), so drop VpcSecurityGroupIds here too.
  NEW_META=$(echo "$META" | jq \
    --arg id "$NEW_DB_ID" \
    --arg sg "$DB_SUBNET_GROUP" \
    '(del(.DBSnapshotIdentifier, .AvailabilityZone, .VpcSecurityGroupIds, .DBParameterGroupName, .OptionGroupName, .DBName)
      | with_entries(select((.key | startswith("InformationalOnly:")) or (.key | startswith("aws:backup:")) | not)))
     + {"DBInstanceIdentifier": $id, "DBSubnetGroupName": $sg, "Port": "5432"}')

  log "Starting restore job..."
  JOB_ID=$(aws backup start-restore-job \
    --recovery-point-arn "$RP_ARN" \
    --iam-role-arn "$BACKUP_ROLE_ARN" \
    --resource-type RDS \
    --metadata "$NEW_META" \
    --region "$DR_REGION" \
    --query RestoreJobId --output text)
  log "Restore job: $JOB_ID"

  while true; do
    STATUS=$(aws backup describe-restore-job --restore-job-id "$JOB_ID" \
      --region "$DR_REGION" --query Status --output text)
    log "  restore status=$STATUS  elapsed=$(( $(date +%s) - START_EPOCH ))s"
    case "$STATUS" in
      COMPLETED) break ;;
      ABORTED|FAILED)
        MSG=$(aws backup describe-restore-job --restore-job-id "$JOB_ID" \
          --region "$DR_REGION" --query StatusMessage --output text)
        echo "ERROR: restore $STATUS — $MSG" >&2; exit 1 ;;
    esac
    sleep 20
  done
  aws rds wait db-instance-available --db-instance-identifier "$NEW_DB_ID" --region "$DR_REGION"
fi

# ---------- 3. Attach the DR security group + reset the master password ----------
# The restored instance preserves the OLD master password, which may be gone with
# the primary region. Reset it to a fresh value we control, and attach the DR SG
# (which already trusts the DR EKS cluster SG) so the app connects locally.
log "Attaching DR security group + resetting master password..."
# Generate the new password from a BOUNDED read of /dev/urandom, then slice in the
# shell. Piping /dev/urandom straight into `tr … | head -c 24` hangs on macOS: head
# exits after 24 bytes but tr never gets SIGPIPE, so it spins on the infinite stream
# at ~100% CPU forever and the script never reaches modify-db-instance. Reading a
# fixed 4 KB chunk lets tr hit EOF and exit; ${VAR:0:24} avoids an early-close pipe.
# Charset stays RDS-Postgres-safe (no / @ " or space).
NEW_PW="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9!#%^*_=+-')"
NEW_PW="${NEW_PW:0:24}"
aws rds modify-db-instance --db-instance-identifier "$NEW_DB_ID" \
  --vpc-security-group-ids "$RDS_SG_ID" \
  --master-user-password "$NEW_PW" \
  --apply-immediately --region "$DR_REGION" >/dev/null

# Poll to available with visible status instead of a mute `aws rds wait`. A password
# reset drops the instance into modifying/resetting-master-credentials for a few
# minutes; the old silent wait made that look like a hang. Log each poll so it's
# obviously alive. The leading sleep rides out the race where the instance still
# reports "available" for a moment before --apply-immediately takes effect.
sleep 10
while true; do
  STATUS=$(aws rds describe-db-instances --db-instance-identifier "$NEW_DB_ID" \
    --region "$DR_REGION" --query 'DBInstances[0].DBInstanceStatus' --output text)
  log "  modify status=$STATUS  elapsed=$(( $(date +%s) - START_EPOCH ))s"
  case "$STATUS" in
    available) break ;;
    modifying|configuring-*|resetting-master-credentials|storage-optimization|backing-up|upgrading) ;;
    *) echo "ERROR: unexpected DB status '$STATUS' during modify." >&2; exit 1 ;;
  esac
  sleep 20
done

# ---------- 4. Write the fresh DR-region credentials secret ----------
read -r DB_USER DB_NAME DB_HOST DB_PORT <<EOF
$(aws rds describe-db-instances --db-instance-identifier "$NEW_DB_ID" --region "$DR_REGION" \
  --query 'DBInstances[0].[MasterUsername,DBName,Endpoint.Address,Endpoint.Port]' --output text)
EOF
[[ -z "$DB_NAME" || "$DB_NAME" == "None" ]] && DB_NAME="$PROJECT"
log "Restored endpoint: $DB_HOST:$DB_PORT  (user=$DB_USER db=$DB_NAME)"

SECRET_JSON=$(DB_USER="$DB_USER" DB_PW="$NEW_PW" DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_NAME="$DB_NAME" \
  python3 -c '
import json, os
from urllib.parse import quote
u = os.environ["DB_USER"]; pw = os.environ["DB_PW"]
host = os.environ["DB_HOST"]; port = int(os.environ["DB_PORT"]); db = os.environ["DB_NAME"]
qu = quote(u, safe=""); qpw = quote(pw, safe="")
dsn = "postgresql://{}:{}@{}:{}/{}".format(qu, qpw, host, port, db)
print(json.dumps({
  "username": u, "password": pw, "engine": "postgres",
  "host": host, "port": port, "dbname": db, "dsn": dsn,
}))')

if aws secretsmanager describe-secret --secret-id "$CRED_SECRET_ID" --region "$DR_REGION" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --secret-id "$CRED_SECRET_ID" \
    --secret-string "$SECRET_JSON" --region "$DR_REGION" >/dev/null
else
  aws secretsmanager create-secret --name "$CRED_SECRET_ID" \
    --secret-string "$SECRET_JSON" --region "$DR_REGION" >/dev/null
fi
log "Wrote credentials secret '$CRED_SECRET_ID' in $DR_REGION."

# ---------- 5. Deploy the app onto the DR cluster (points at the LOCAL DB) ----------
if is_true "$DEPLOY_APP"; then
  log "Deploying the app onto the DR cluster..."
  AWS_REGION="$DR_REGION" \
  CLUSTER_NAME="$CLUSTER" \
  NAMESPACE="$NAMESPACE" \
  RDS_SECRET_ID="$CRED_SECRET_ID" \
  ENSURE_LB_CONTROLLER="${ENSURE_LB_CONTROLLER:-1}" \
    "$REPO_ROOT/scripts/deploy-eks-k8s.sh"
else
  log "DEPLOY_APP=0 — skipping the kubectl deploy."
fi

TOTAL=$(( $(date +%s) - START_EPOCH ))
log "RECOVERY COMPLETE in ${TOTAL}s."
log "Restored DB: $NEW_DB_ID  ($(report_endpoint):5432)"
log "The rebuilt app and restored DB are co-located in $DR_REGION — local, no cross-region reach."
