#!/usr/bin/env bash
#
# teardown-all.sh — FULL, ordered teardown of the whole FinCorp lab.
#
# Destroys everything across all three Terraform roots, handling the out-of-band
# and dependency-blocking resources Terraform can't remove on its own, in the
# right order so each `terraform destroy` succeeds cleanly:
#
#   DR region (eu-west-2)      1. K8s app + Ingress/ALB (frees ENIs/public IPs)
#                             2. DR-restored RDS instance (frees the DB subnet group)
#                             3. purge stray load balancers + drain ENIs
#                             4. terraform destroy infra/live-dr
#   Primary region (eu-west-1) 5. K8s app + Ingress/ALB
#                             6. purge stray load balancers + drain ENIs
#                             7. terraform destroy infra/live-primary
#   Persistent                8. empty ECR repos (primary + eu-west-2 replicas)
#                             9. delete recovery points in both vaults
#                            10. terraform destroy infra/live-persistent
#
# Order matters: the regional stacks go first (their ALBs/DBs block VPC deletion),
# persistent goes last (it holds the backups + images the recovery needs). Runs
# best-effort (keeps going past individual failures) and is safe to re-run.
#
# Flags:
#   --yes               skip the confirmation prompt
#   --keep-persistent   destroy the regional stacks but KEEP the persistent layer
#                       (backups, ECR, OIDC) — e.g. to rebuild primary later
#   --cleanup-only      do the out-of-band cleanup but do NOT run terraform destroy
#   -h, --help          show this help
#
# Env overrides:
#   PROJECT=fincorp  PRIMARY_REGION=eu-west-1  DR_REGION=eu-west-2
#   CLUSTER=fincorp  NS=fincorp  RESTORED_DB_ID=fincorp-db-restored
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PRIMARY_DIR="$REPO_ROOT/infra/live-primary"
DR_DIR="$REPO_ROOT/infra/live-dr"
PERSISTENT_DIR="$REPO_ROOT/infra/live-persistent"

ASSUME_YES=0
KEEP_PERSISTENT=0
CLEANUP_ONLY=0
for a in "$@"; do
  case "$a" in
    --yes) ASSUME_YES=1 ;;
    --keep-persistent) KEEP_PERSISTENT=1 ;;
    --cleanup-only) CLEANUP_ONLY=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
  esac
done

log() { printf '\033[1;33m[teardown]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------- helpers ----------------

# Resolve a stack's VPC id: prefer terraform output, fall back to the Name tag.
get_vpc_id() {
  local dir="$1" region="$2" vid
  vid="$(terraform -chdir="$dir" output -raw vpc_id 2>/dev/null || true)"
  if [[ -z "$vid" || "$vid" == "None" ]]; then
    vid="$(aws ec2 describe-vpcs --region "$region" \
      --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
      --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  fi
  [[ "$vid" == "None" ]] && vid=""
  echo "$vid"
}

# Delete the K8s app + Ingress/ALB cleanly (LB Controller releases the ALB), if
# the cluster is reachable. Reuses teardown-eks-k8s.sh.
k8s_lb_cleanup() {
  local region="$1"
  local status
  status="$(aws eks describe-cluster --name "$CLUSTER" --region "$region" \
    --query 'cluster.status' --output text 2>/dev/null || echo NONE)"
  if [[ "$status" != "ACTIVE" ]]; then
    log "  EKS '$CLUSTER' in $region: $status — skipping K8s cleanup"
    return
  fi
  if [[ -x "$HERE/teardown-eks-k8s.sh" ]]; then
    log "  removing K8s app + Ingress/ALB on '$CLUSTER' ($region)..."
    ALB_CLEANUP_WAIT_SECONDS=90 "$HERE/teardown-eks-k8s.sh" \
      --region "$region" --cluster "$CLUSTER" --namespace "$NS" \
      --include-ingress --delete-namespace \
      || log "  (teardown-eks-k8s.sh reported errors — continuing)"
  else
    log "  teardown-eks-k8s.sh missing — deleting ingress via kubectl"
    aws eks update-kubeconfig --name "$CLUSTER" --region "$region" >/dev/null 2>&1 || true
    kubectl delete ingress --all -n "$NS" --ignore-not-found 2>/dev/null || true
    kubectl delete svc -n "$NS" --field-selector spec.type=LoadBalancer --ignore-not-found 2>/dev/null || true
  fi
}

# Force-delete any ALB/NLB/classic ELB still in a VPC, then wait for their ENIs to
# drain (otherwise subnet + IGW deletion fails with DependencyViolation).
purge_load_balancers() {
  local vpc="$1" region="$2"
  [[ -z "$vpc" ]] && { log "  no VPC id for $region — skipping LB purge"; return; }
  local arn lb n i
  for arn in $(aws elbv2 describe-load-balancers --region "$region" \
      --query "LoadBalancers[?VpcId=='$vpc'].LoadBalancerArn" --output text 2>/dev/null); do
    log "  deleting ALB/NLB ${arn##*/}"
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$region" 2>/dev/null || true
  done
  for lb in $(aws elb describe-load-balancers --region "$region" \
      --query "LoadBalancerDescriptions[?VPCId=='$vpc'].LoadBalancerName" --output text 2>/dev/null); do
    log "  deleting classic ELB $lb"
    aws elb delete-load-balancer --load-balancer-name "$lb" --region "$region" 2>/dev/null || true
  done
  for i in $(seq 1 24); do
    n=$(aws ec2 describe-network-interfaces --region "$region" \
      --filters "Name=vpc-id,Values=$vpc" "Name=description,Values=ELB *" \
      --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
    [[ -z "$n" || "$n" == "0" ]] && { [[ "$i" -gt 1 ]] && log "  LB ENIs drained in $region"; return; }
    sleep 10
  done
  log "  LB ENIs still draining in $region — destroy may need a retry"
}

# Delete an RDS instance and wait for it to be gone.
delete_rds() {
  local id="$1" region="$2"
  if aws rds describe-db-instances --db-instance-identifier "$id" --region "$region" >/dev/null 2>&1; then
    log "  deleting RDS '$id' ($region)..."
    aws rds delete-db-instance --db-instance-identifier "$id" \
      --skip-final-snapshot --delete-automated-backups --region "$region" >/dev/null 2>&1 || true
    aws rds wait db-instance-deleted --db-instance-identifier "$id" --region "$region" 2>/dev/null || true
    log "  '$id' deleted."
  else
    log "  RDS '$id' ($region) not present."
  fi
}

# Delete recovery points so the vault can be destroyed.
purge_vault() {
  local vault="$1" region="$2" arns n
  aws backup describe-backup-vault --backup-vault-name "$vault" --region "$region" >/dev/null 2>&1 || {
    log "  vault $vault ($region) not present — skipping"; return; }
  arns=$(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" \
    --region "$region" --query 'RecoveryPoints[].RecoveryPointArn' --output text 2>/dev/null)
  if [[ -z "$arns" ]]; then log "  $vault ($region): no recovery points"; return; fi
  for arn in $arns; do
    aws backup delete-recovery-point --backup-vault-name "$vault" --recovery-point-arn "$arn" \
      --region "$region" >/dev/null 2>&1 && log "  deleted RP in $vault: ${arn##*/}"
  done
  for _ in $(seq 1 30); do
    n=$(aws backup describe-backup-vault --backup-vault-name "$vault" --region "$region" \
      --query NumberOfRecoveryPoints --output text 2>/dev/null || echo 0)
    [[ "$n" == "0" ]] && { log "  $vault ($region): now empty"; return; }
    sleep 10
  done
  log "  $vault ($region): still draining — terraform destroy may need a retry"
}

# Empty ECR repos (repos have no force_delete, so images must go first).
empty_ecr() {
  local region="$1" repo ids
  for repo in "${ECR_REPOS[@]}"; do
    ids=$(aws ecr list-images --repository-name "$repo" --region "$region" \
      --query 'imageIds[*]' --output json 2>/dev/null || echo "[]")
    if [[ "$ids" != "[]" && -n "$ids" ]]; then
      aws ecr batch-delete-image --repository-name "$repo" --region "$region" \
        --image-ids "$ids" >/dev/null 2>&1 && log "  emptied $repo ($region)" \
        || log "  could not empty $repo ($region)"
    else
      log "  $repo ($region): already empty / absent"
    fi
  done
}

# terraform destroy a root, with one retry (ENIs/LBs sometimes need a moment).
tf_destroy() {
  local dir="$1" label="$2"
  [[ -f "$dir/main.tf" ]] || { log "  $label: no config at $dir — skipping"; return; }
  terraform -chdir="$dir" init -input=false >/dev/null 2>&1
  if [[ -z "$(terraform -chdir="$dir" state list 2>/dev/null)" ]]; then
    log "  $label: state empty — nothing to destroy"; return
  fi
  log "  $label: terraform destroy..."
  if terraform -chdir="$dir" destroy -auto-approve; then
    log "  $label: destroyed."; return
  fi
  log "  $label: first destroy failed — retrying once..."
  terraform -chdir="$dir" destroy -auto-approve \
    && log "  $label: destroyed on retry." \
    || log "  $label: STILL failing — inspect the error above."
}

# ---------------- confirm ----------------
echo
echo "⚠️  FULL teardown for project '$PROJECT'. This will:"
echo "   - delete K8s workloads + Ingress/ALB in cluster '$CLUSTER' (both regions)"
echo "   - delete the DR-restored DB '$RESTORED_DB_ID' ($DR_REGION)"
echo "   - delete ALL images in: ${ECR_REPOS[*]} (both regions)"
echo "   - delete ALL recovery points in '$PRIMARY_VAULT' + '$DR_VAULT'"
if [[ "$CLEANUP_ONLY" -eq 1 ]]; then
  echo "   - (cleanup only — NOT running terraform destroy)"
else
  echo "   - terraform destroy: live-dr, live-primary$([[ "$KEEP_PERSISTENT" -eq 1 ]] && echo ' (KEEP persistent)' || echo ', live-persistent')"
fi
echo
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Type 'destroy' to proceed: " REPLY
  [[ "$REPLY" == "destroy" ]] || { echo "Aborted."; exit 1; }
fi

START=$(date +%s)

# ================= DR region (eu-west-2) =================
step "DR region ($DR_REGION)"
k8s_lb_cleanup "$DR_REGION"
delete_rds "$RESTORED_DB_ID" "$DR_REGION"        # free the DR DB subnet group
DR_VPC="$(get_vpc_id "$DR_DIR" "$DR_REGION")"
purge_load_balancers "$DR_VPC" "$DR_REGION"
if [[ "$CLEANUP_ONLY" -ne 1 ]]; then tf_destroy "$DR_DIR" "live-dr"; fi

# ================= Primary region (eu-west-1) =================
step "Primary region ($PRIMARY_REGION)"
k8s_lb_cleanup "$PRIMARY_REGION"
PRIMARY_VPC="$(get_vpc_id "$PRIMARY_DIR" "$PRIMARY_REGION")"
purge_load_balancers "$PRIMARY_VPC" "$PRIMARY_REGION"
if [[ "$CLEANUP_ONLY" -ne 1 ]]; then tf_destroy "$PRIMARY_DIR" "live-primary"; fi

# ================= Persistent layer =================
step "Persistent layer (backups, ECR, OIDC)"
empty_ecr "$PRIMARY_REGION"
empty_ecr "$DR_REGION"                            # eu-west-2 replicas
purge_vault "$PRIMARY_VAULT" "$PRIMARY_REGION"
purge_vault "$DR_VAULT" "$DR_REGION"
if [[ "$CLEANUP_ONLY" -eq 1 ]]; then
  log "cleanup-only: skipping terraform destroy of persistent."
elif [[ "$KEEP_PERSISTENT" -eq 1 ]]; then
  log "--keep-persistent: leaving the persistent layer in place."
else
  # eu-west-2 replica repos are auto-created by replication (not in TF state) —
  # remove them explicitly so nothing is left behind.
  for repo in "${ECR_REPOS[@]}"; do
    aws ecr delete-repository --repository-name "$repo" --region "$DR_REGION" --force >/dev/null 2>&1 \
      && log "  deleted replica repo $repo ($DR_REGION)" || true
  done
  tf_destroy "$PERSISTENT_DIR" "live-persistent"
fi

echo
log "Teardown finished in $(( $(date +%s) - START ))s."
if [[ "$CLEANUP_ONLY" -eq 1 ]]; then
  log "Cleanup done. Run terraform destroy yourself: live-dr, live-primary, live-persistent."
fi
