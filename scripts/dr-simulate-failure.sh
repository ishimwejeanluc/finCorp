#!/usr/bin/env bash
#
# dr-simulate-failure.sh — Simulate a FULL primary-region failure by destroying
# the entire primary stack (app + EKS + Redis + RDS + VPC) in eu-west-1.
#
# This is the "region failure" step of the DR drill. It runs `terraform destroy`
# against infra/live-primary ONLY — the persistent layer (backup vaults + the DR
# recovery point, ECR images + their eu-west-2 replica, the GitHub OIDC role) and
# the Terraform state bucket are in separate states and are left untouched, so
# there is still something to rebuild + restore from.
#
# Recover afterwards with scripts/dr-restore.sh.
#
# SAFETY: refuses to run unless a COMPLETED recovery point already exists in the
# DR vault (eu-west-2) — otherwise you'd have nothing to restore from. Requires an
# explicit confirmation before destroying.
#
# Optional env / flags:
#   PROJECT          default: fincorp
#   PRIMARY_REGION   default: eu-west-1
#   DR_REGION        default: eu-west-2
#   DR_VAULT         default: ${PROJECT}-backup-dr
#   PRIMARY_DIR      default: infra/live-primary
#   --yes            skip the interactive confirmation (for automation)
#
set -euo pipefail

PROJECT="${PROJECT:-fincorp}"
PRIMARY_REGION="${PRIMARY_REGION:-eu-west-1}"
DR_REGION="${DR_REGION:-eu-west-2}"
DR_VAULT="${DR_VAULT:-${PROJECT}-backup-dr}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIMARY_DIR="${PRIMARY_DIR:-${REPO_ROOT}/infra/live-primary}"
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
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
  echo "       Destroying the primary now would be unrecoverable." >&2
  echo "       Create + copy a backup first (see docs/04-dr-setup.md), then retry." >&2
  exit 1
fi
log "OK — $RP_COUNT recovery point(s) available in $DR_REGION. Recovery is possible."

# ---------- 2. Confirm the primary stack exists ----------
if [[ ! -d "$PRIMARY_DIR" ]]; then
  echo "ERROR: primary stack dir not found: $PRIMARY_DIR" >&2
  exit 1
fi
CLUSTER_STATUS=$(aws eks describe-cluster --name "$PROJECT" --region "$PRIMARY_REGION" \
  --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")
log "Primary EKS cluster '$PROJECT' in $PRIMARY_REGION: $CLUSTER_STATUS"

# ---------- 3. Explicit confirmation ----------
if [[ "$ASSUME_YES" -ne 1 ]]; then
  echo
  echo "⚠️  This runs 'terraform destroy' on the WHOLE primary stack in $PRIMARY_REGION:"
  echo "     EKS cluster + nodes, the app, ElastiCache, RDS ($PROJECT-db), the VPC."
  echo "    The persistent layer (backups, ECR, OIDC) and state bucket are NOT touched."
  read -r -p "Type the project name to confirm: " REPLY
  if [[ "$REPLY" != "$PROJECT" ]]; then
    echo "Confirmation did not match. Aborting." >&2
    exit 1
  fi
fi

# ---------- 4. Destroy = simulate the region failure (RTO clock starts) ----------
START_EPOCH=$(date +%s)
log "RTO CLOCK START: $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "Destroying the primary stack in $PRIMARY_DIR ..."

terraform -chdir="$PRIMARY_DIR" init -input=false >/dev/null
terraform -chdir="$PRIMARY_DIR" destroy -auto-approve

log "Primary stack destroyed after $(( $(date +%s) - START_EPOCH ))s."
echo
log "FULL region failure simulated. Now RECOVER in $DR_REGION:"
echo "    ./scripts/dr-restore.sh"
log "Measure RTO from the CLOCK START above to when dr-restore.sh reports COMPLETE."
