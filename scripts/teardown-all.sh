#!/usr/bin/env bash
#
# teardown-all.sh — PRE-DESTROY cleanup. Removes everything `terraform destroy`
# can't remove on its own (out-of-band or dependency-blocking resources), so the
# destroy afterwards succeeds cleanly. This script does NOT run terraform destroy
# — run it yourself after this finishes.
#
# It removes, in order:
#   1. K8s app + Ingress(->ALB) + LB controller + namespace  (via teardown-eks-k8s.sh)
#   2. The DR-restored RDS instance in eu-west-2 (AWS Backup made it; not in TF state)
#   3. All images in the ECR repos (repos have no force_delete)
#   4. All recovery points in BOTH backup vaults (a vault won't destroy otherwise)
#
# Everything else (VPC, EKS, primary RDS, CodeArtifact, KMS, vaults, IAM, secrets)
# is left for `terraform destroy`.
#
# Optional env / flags:
#   PROJECT=fincorp  PRIMARY_REGION=eu-west-1  DR_REGION=eu-west-2
#   CLUSTER=fincorp  NS=fincorp  RESTORED_DB_ID=fincorp-db-restored
#   --yes   skip the confirmation prompt
#
set -uo pipefail   # NOT -e: cleanup is best-effort; keep going past individual failures

PROJECT="${PROJECT:-fincorp}"
PRIMARY_REGION="${PRIMARY_REGION:-eu-west-1}"
DR_REGION="${DR_REGION:-eu-west-2}"
CLUSTER="${CLUSTER:-fincorp}"
NS="${NS:-fincorp}"
RESTORED_DB_ID="${RESTORED_DB_ID:-${PROJECT}-db-restored}"
PRIMARY_VAULT="${PRIMARY_VAULT:-${PROJECT}-backup-primary}"
DR_VAULT="${DR_VAULT:-${PROJECT}-backup-dr}"
ECR_REPOS=("${PROJECT}/backend" "${PROJECT}/frontend")
ASSUME_YES=0
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '\033[1;33m[teardown]\033[0m %s\n' "$*"; }

echo
echo "⚠️  PRE-DESTROY cleanup for project '$PROJECT'. This will:"
echo "   - delete K8s workloads + Ingress/ALB + LB controller in cluster '$CLUSTER'"
echo "   - delete the DR-restored DB '$RESTORED_DB_ID' in $DR_REGION"
echo "   - delete ALL images in: ${ECR_REPOS[*]}"
echo "   - delete ALL recovery points in vaults '$PRIMARY_VAULT' ($PRIMARY_REGION) and '$DR_VAULT' ($DR_REGION)"
echo "   It does NOT run terraform destroy."
echo
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Type 'destroy' to proceed: " REPLY
  [[ "$REPLY" == "destroy" ]] || { echo "Aborted."; exit 1; }
fi

# ---------- 1. Kubernetes: app + ingress(->ALB) + LB controller + namespace ----------
log "1/4  Tearing down Kubernetes resources (frees the ALB/ENIs in the VPC)..."
if [[ -x "$HERE/teardown-eks-k8s.sh" ]]; then
  "$HERE/teardown-eks-k8s.sh" --region "$PRIMARY_REGION" --cluster "$CLUSTER" \
    --namespace "$NS" --include-ingress --remove-lb-controller --delete-namespace || \
    log "  (teardown-eks-k8s.sh reported errors — continuing)"
else
  log "  teardown-eks-k8s.sh not found/executable — skipping k8s teardown"
fi

# ---------- 2. DR-restored RDS instance (eu-west-2) ----------
log "2/4  Deleting DR-restored instance '$RESTORED_DB_ID' in $DR_REGION (if present)..."
if aws rds describe-db-instances --db-instance-identifier "$RESTORED_DB_ID" --region "$DR_REGION" >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier "$RESTORED_DB_ID" \
    --skip-final-snapshot --delete-automated-backups --region "$DR_REGION" >/dev/null 2>&1 \
    && log "  delete initiated; waiting..." \
    && aws rds wait db-instance-deleted --db-instance-identifier "$RESTORED_DB_ID" --region "$DR_REGION" 2>/dev/null \
    && log "  deleted."
else
  log "  not present — nothing to do."
fi

# ---------- 3. Empty the ECR repos ----------
log "3/4  Emptying ECR repos..."
for repo in "${ECR_REPOS[@]}"; do
  IDS=$(aws ecr list-images --repository-name "$repo" --region "$PRIMARY_REGION" \
    --query 'imageIds[*]' --output json 2>/dev/null || echo "[]")
  if [[ "$IDS" != "[]" && -n "$IDS" ]]; then
    aws ecr batch-delete-image --repository-name "$repo" --region "$PRIMARY_REGION" \
      --image-ids "$IDS" >/dev/null 2>&1 && log "  emptied $repo" || log "  could not empty $repo (may not exist)"
  else
    log "  $repo already empty / absent"
  fi
done

# ---------- 4. Delete all recovery points in both vaults ----------
purge_vault() {
  local vault="$1" region="$2"
  aws backup describe-backup-vault --backup-vault-name "$vault" --region "$region" >/dev/null 2>&1 || {
    log "  vault $vault ($region) not present — skipping"; return; }
  local arns
  arns=$(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" \
    --region "$region" --query 'RecoveryPoints[].RecoveryPointArn' --output text 2>/dev/null)
  if [[ -z "$arns" ]]; then log "  $vault ($region): no recovery points"; return; fi
  for arn in $arns; do
    aws backup delete-recovery-point --backup-vault-name "$vault" --recovery-point-arn "$arn" \
      --region "$region" >/dev/null 2>&1 && log "  deleted RP in $vault: ${arn##*/}"
  done
  # Wait until the vault reports zero (deletes are async; vault destroy needs 0).
  for _ in $(seq 1 30); do
    local n
    n=$(aws backup describe-backup-vault --backup-vault-name "$vault" --region "$region" \
      --query NumberOfRecoveryPoints --output text 2>/dev/null || echo 0)
    [[ "$n" == "0" ]] && { log "  $vault ($region): now empty"; return; }
    sleep 10
  done
  log "  $vault ($region): still draining recovery points — terraform destroy may need a retry"
}
log "4/4  Deleting recovery points in both vaults..."
purge_vault "$PRIMARY_VAULT" "$PRIMARY_REGION"
purge_vault "$DR_VAULT" "$DR_REGION"

echo
log "Pre-destroy cleanup complete."
log "Now run (in order):"
log "  terraform -chdir=infra/live-dr        destroy   # if ever applied"
log "  terraform -chdir=infra/live-primary   destroy"
log "  terraform -chdir=infra/live-persistent destroy"
