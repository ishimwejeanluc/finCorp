#!/usr/bin/env bash
#
# dr-simulate-failure.sh — Simulate a primary-region failure by DELETING the
# primary RDS database. This is the "region failure" step of the DR drill;
# recover afterwards with scripts/dr-restore.sh.
#
# SAFETY: refuses to run unless a COMPLETED recovery point already exists in the
# DR vault (eu-west-2) — otherwise you'd have nothing to restore from. Requires
# an explicit confirmation before deleting.
#
# Optional env / flags:
#   PROJECT          default: fincorp
#   PRIMARY_REGION   default: eu-west-1
#   DR_REGION        default: eu-west-2
#   DB_ID            default: ${PROJECT}-db
#   DR_VAULT         default: ${PROJECT}-backup-dr
#   --yes            skip the interactive confirmation (for automation)
#   --wait           block until the instance is fully deleted
#
set -euo pipefail

PROJECT="${PROJECT:-fincorp}"
PRIMARY_REGION="${PRIMARY_REGION:-eu-west-1}"
DR_REGION="${DR_REGION:-eu-west-2}"
DB_ID="${DB_ID:-${PROJECT}-db}"
DR_VAULT="${DR_VAULT:-${PROJECT}-backup-dr}"
ASSUME_YES=0
WAIT=0

for arg in "$@"; do
  case "$arg" in
    --yes)  ASSUME_YES=1 ;;
    --wait) WAIT=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

log() { printf '\033[1;31m[dr-sim]\033[0m %s\n' "$*"; }

# ---------- 1. Safety: a recovery point MUST exist in the DR region ----------
log "Checking for a recovery point in DR vault '$DR_VAULT' ($DR_REGION)..."
RP_COUNT=$(aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name "$DR_VAULT" --region "$DR_REGION" --by-resource-type RDS \
  --query 'length(RecoveryPoints[?Status==`COMPLETED`])' --output text 2>/dev/null || echo 0)

if [[ -z "$RP_COUNT" || "$RP_COUNT" == "0" || "$RP_COUNT" == "None" ]]; then
  echo "ABORT: no COMPLETED recovery point in $DR_VAULT ($DR_REGION)." >&2
  echo "       Deleting the primary now would be unrecoverable." >&2
  echo "       Create + copy a backup first (see docs/04-dr-setup.md), then retry." >&2
  exit 1
fi
log "OK — $RP_COUNT recovery point(s) available in $DR_REGION. Recovery is possible."

# ---------- 2. Confirm the primary exists ----------
STATUS=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --region "$PRIMARY_REGION" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$STATUS" == "NOT_FOUND" ]]; then
  echo "Primary DB '$DB_ID' not found in $PRIMARY_REGION — already deleted?" >&2
  exit 1
fi
log "Primary DB '$DB_ID' is currently: $STATUS"

# ---------- 3. Explicit confirmation ----------
if [[ "$ASSUME_YES" -ne 1 ]]; then
  echo
  echo "⚠️  This DELETES the primary database '$DB_ID' in $PRIMARY_REGION (no final snapshot)."
  read -r -p "Type the DB identifier to confirm: " REPLY
  if [[ "$REPLY" != "$DB_ID" ]]; then
    echo "Confirmation did not match. Aborting." >&2
    exit 1
  fi
fi

# ---------- 4. Delete = simulate the region failure (RTO clock starts) ----------
START_EPOCH=$(date +%s)
log "RTO CLOCK START: $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "Deleting primary DB '$DB_ID'..."
aws rds delete-db-instance \
  --db-instance-identifier "$DB_ID" \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region "$PRIMARY_REGION" \
  --query 'DBInstance.DBInstanceStatus' --output text

if [[ "$WAIT" -eq 1 ]]; then
  log "Waiting for the instance to fully delete..."
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID" --region "$PRIMARY_REGION" || true
  log "Deleted after $(( $(date +%s) - START_EPOCH ))s."
fi

echo
log "Region failure simulated. Now RECOVER in $DR_REGION:"
echo "    export BACKUP_ROLE_ARN=\"\$(cd infra/live-fincorp && terraform output -raw backup_role_arn)\""
echo "    ./scripts/dr-restore.sh"
log "Measure RTO from the CLOCK START above to when dr-restore.sh reports COMPLETE."
