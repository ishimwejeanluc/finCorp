#!/usr/bin/env bash
# Deploy FinCorp K8s manifests to an existing EKS cluster.
# Does NOT build/push images - run scripts/push-ecr.sh first if needed.
set -euo pipefail

# Ride out transient network/DNS blips instead of aborting — AWS CLI auto-retries.
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"

AWS_REGION="${AWS_REGION:-eu-west-1}"
CLUSTER_NAME="${CLUSTER_NAME:-fincorp}"
NAMESPACE="${NAMESPACE:-fincorp}"

BACKEND_REPO="${BACKEND_REPO:-fincorp/backend}"
FRONTEND_REPO="${FRONTEND_REPO:-fincorp/frontend}"
IMAGE_TAG="${IMAGE_TAG:-}"
ACCOUNT_ID="${ACCOUNT_ID:-}"
# Registry host the images are pulled from. Defaults to the account's ECR in the
# target region — so a DR deploy (AWS_REGION=eu-west-2) pulls the replicated image
# from the eu-west-2 registry, not the hardcoded eu-west-1 host in the manifest.
ECR_REGISTRY="${ECR_REGISTRY:-}"

RDS_SECRET_ID="${RDS_SECRET_ID:-fincorp/rds/credentials}"
SKIP_SECRET="${SKIP_SECRET:-0}"
INCLUDE_INGRESS="${INCLUDE_INGRESS:-1}"
# LB controller install is a one-time, helm-based cluster setup. Off by default
# so CI (which has no helm and shouldn't re-install it every deploy) can apply the
# ingress without it. Run once locally with --ensure-lb-controller.
ENSURE_LB_CONTROLLER="${ENSURE_LB_CONTROLLER:-0issue when }"

usage() {
  cat <<'EOF'
Usage: scripts/deploy-eks-k8s.sh [options]

Applies the k8s/ manifests to an EKS cluster. Does not build or push images -
run scripts/push-ecr.sh first if you need to ship new image bytes.

Options:
  --region <aws-region>         AWS region (default: eu-west-1)
  --cluster <cluster-name>      EKS cluster name (default: fincorp)
  --namespace <namespace>       Kubernetes namespace (default: fincorp)
  --image-tag <tag>             Image tag to deploy (rendered into both
                                Deployments before apply). Default: latest tag
                                pushed to ECR.
  --account-id <id>             AWS account ID for image URI (default: auto-detect)
  --rds-secret-id <id>          Secrets Manager ID for Postgres creds
  --skip-secret                 Skip creating/updating the fincorp-db Secret
  --include-ingress             Apply k8s/06-ingress.yaml (default: on)
  --no-ingress                  Do not apply the ingress
  --ensure-lb-controller        Install/upgrade the AWS LB Controller (helm, one-time)
  -h, --help                    Show this help

Environment variable equivalents:
  AWS_REGION, CLUSTER_NAME, NAMESPACE, IMAGE_TAG, ACCOUNT_ID, RDS_SECRET_ID,
  SKIP_SECRET=1, INCLUDE_INGRESS=1, ENSURE_LB_CONTROLLER=1

Examples:
  scripts/deploy-eks-k8s.sh --image-tag "$GIT_SHA"          # used by the pipeline
  scripts/deploy-eks-k8s.sh --ensure-lb-controller          # first-time cluster setup
  scripts/deploy-eks-k8s.sh --skip-secret                   # redeploy latest image
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

bool_true() {
  local v="${1:-0}"
  [[ "$v" == "1" || "$v" == "true" || "$v" == "TRUE" || "$v" == "yes" || "$v" == "YES" ]]
}

create_or_update_db_secret() {
  local namespace="$1"

  # Build the DSN in-script and URL-encode credentials so special chars
  # in the auto-generated password (#, !, <, >, $, etc.) don't break parsing.
  local pg_dsn
  pg_dsn="$(aws secretsmanager get-secret-value \
    --secret-id "$RDS_SECRET_ID" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text | python3 -c '
import json, sys
from urllib.parse import quote
d = json.load(sys.stdin)
user = quote(d["username"], safe="")
pw   = quote(d["password"], safe="")
host = d["host"]
port = d.get("port", 5432)
db   = d.get("dbname", "fincorp")
print(f"postgresql://{user}:{pw}@{host}:{port}/{db}")
')"

  kubectl -n "$namespace" create secret generic fincorp-db \
    --from-literal=POSTGRES_DSN="$pg_dsn" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# Echo the image tag to deploy for a repo. Uses --image-tag if given, else the
# most recently pushed tag in ECR (handy for local runs after a pipeline build).
deploy_image_tag() {
  local repo="$1"
  if [[ -n "$IMAGE_TAG" ]]; then
    echo "$IMAGE_TAG"
    return
  fi
  local t
  t="$(aws ecr describe-images --repository-name "$repo" --region "$AWS_REGION" \
        --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' \
        --output text 2>/dev/null || true)"
  if [[ -z "$t" || "$t" == "None" ]]; then
    echo "ERROR: no --image-tag given and no images found in $repo." >&2
    echo "       Run the pipeline (or push-ecr.sh) first, or pass --image-tag." >&2
    exit 1
  fi
  echo "$t"
}

# Render the placeholder tag in the deployment manifests to the real image and
# apply declaratively. Rendering BEFORE apply (instead of apply-then-set-image)
# keeps it idempotent and avoids momentarily rolling out the non-pulling
# :placeholder tag. Unchanged manifests are left untouched by kubectl apply.
render_and_apply() {
  local k8s_dir="$1" tmp btag ftag
  tmp="$(mktemp -d)"
  cp "$k8s_dir"/*.yaml "$tmp"/

  btag="$(deploy_image_tag "$BACKEND_REPO")"
  ftag="$(deploy_image_tag "$FRONTEND_REPO")"
  echo "Backend image tag:  $btag"
  echo "Frontend image tag: $ftag"

  # Rewrite the FULL image reference (registry host + repo + tag) so the deploy is
  # region-portable: the manifest hardcodes the eu-west-1 host, but ECR_REGISTRY
  # points at whatever region we're deploying into (eu-west-2 on DR failover).
  sed -E "s#image: .*/${BACKEND_REPO}:placeholder#image: ${ECR_REGISTRY}/${BACKEND_REPO}:${btag}#" \
    "$k8s_dir/02-backend-deployment.yaml" > "$tmp/02-backend-deployment.yaml"
  sed -E "s#image: .*/${FRONTEND_REPO}:placeholder#image: ${ECR_REGISTRY}/${FRONTEND_REPO}:${ftag}#" \
    "$k8s_dir/04-frontend-deployment.yaml" > "$tmp/04-frontend-deployment.yaml"

  kubectl apply -f "$tmp/02-backend-deployment.yaml"
  kubectl apply -f "$tmp/03-backend-service.yaml"
  kubectl apply -f "$tmp/04-frontend-deployment.yaml"
  kubectl apply -f "$tmp/05-frontend-service.yaml"
  kubectl apply -f "$tmp/07-db-migrate.yaml"

  if bool_true "$INCLUDE_INGRESS"; then
    kubectl apply -f "$tmp/06-ingress.yaml"
  fi

  rm -rf "$tmp"
}

ensure_lb_controller() {
  # Idempotent helm upgrade --install. Picks up value changes on existing releases.
  need_cmd helm

  echo "Installing/upgrading AWS Load Balancer Controller (Helm, IRSA)..."

  local vpc_id role_name role_arn
  vpc_id="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    echo "Could not discover VPC ID for cluster $CLUSTER_NAME" >&2
    exit 1
  fi

  role_name="${CLUSTER_NAME}-lb-controller"
  # Resolve the IRSA role ARN WITHOUT iam:GetRole (the CI role doesn't have it,
  # so the old `aws iam get-role` lookup failed in the pipeline with AccessDenied).
  # Use an explicit override if provided, else construct it from the account id
  # (sts:GetCallerIdentity is always allowed). Terraform creates this role as
  # ${project}-lb-controller. Locally this yields the identical ARN.
  if [[ -n "${LB_CONTROLLER_ROLE_ARN:-}" ]]; then
    role_arn="$LB_CONTROLLER_ROLE_ARN"
  else
    local account_id
    account_id="$(aws sts get-caller-identity --query Account --output text)"
    role_arn="arn:aws:iam::${account_id}:role/${role_name}"
  fi

  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
  helm repo update eks >/dev/null

  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set region="$AWS_REGION" \
    --set vpcId="$vpc_id" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$role_arn" \
    --wait

  echo "AWS Load Balancer Controller installed (IRSA: $role_arn)."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --region)
        AWS_REGION="$2"
        shift 2
        ;;
      --cluster)
        CLUSTER_NAME="$2"
        shift 2
        ;;
      --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --image-tag)
        IMAGE_TAG="$2"
        shift 2
        ;;
      --account-id)
        ACCOUNT_ID="$2"
        shift 2
        ;;
      --rds-secret-id)
        RDS_SECRET_ID="$2"
        shift 2
        ;;
      --skip-secret)
        SKIP_SECRET="1"
        shift
        ;;
      --include-ingress)
        INCLUDE_INGRESS="1"
        shift
        ;;
      --no-ingress)
        INCLUDE_INGRESS="0"
        shift
        ;;
      --ensure-lb-controller)
        ENSURE_LB_CONTROLLER="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  need_cmd aws
  need_cmd kubectl
  need_cmd python3

  local root k8s_dir
  root="$(repo_root)"
  k8s_dir="$root/k8s"

  [[ -d "$k8s_dir" ]] || {
    echo "k8s directory not found: $k8s_dir" >&2
    exit 1
  }

  if [[ -z "$ACCOUNT_ID" ]]; then
    ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  fi
  if [[ -z "$ECR_REGISTRY" ]]; then
    ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  fi

  echo "Region:       $AWS_REGION"
  echo "ECR registry: $ECR_REGISTRY"
  echo "Cluster:      $CLUSTER_NAME"
  echo "Namespace:    $NAMESPACE"
  echo "K8s dir:      $k8s_dir"
  echo "Account ID:   $ACCOUNT_ID"

  echo "Updating kubeconfig for EKS cluster..."
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

  echo "Applying namespace and configmap..."
  kubectl apply -f "$k8s_dir/00-namespace.yaml"
  kubectl apply -f "$k8s_dir/01-configmap.yaml"

  if ! bool_true "$SKIP_SECRET"; then
    echo "Creating/updating secret: fincorp-db"
    create_or_update_db_secret "$NAMESPACE"
  else
    echo "Skipping secret creation/update (SKIP_SECRET=$SKIP_SECRET)"
  fi

  # One-time cluster setup (helm). Apply ingress always; install controller only
  # when explicitly asked (it provisions the ALB the ingress needs).
  if bool_true "$ENSURE_LB_CONTROLLER"; then
    ensure_lb_controller
  fi

  echo "Rendering image tags and applying deployments/services/ingress..."
  render_and_apply "$k8s_dir"

  echo "Waiting for rollouts..."
  kubectl -n "$NAMESPACE" rollout status deployment/backend  --timeout=180s
  kubectl -n "$NAMESPACE" rollout status deployment/frontend --timeout=180s

  echo "Deployment complete. Current resources:"
  kubectl -n "$NAMESPACE" get pods,svc,ingress

  echo "Tip: If frontend service is LoadBalancer or ingress is enabled, run:"
  echo "  kubectl -n $NAMESPACE get svc frontend"
  echo "  kubectl -n $NAMESPACE get ingress"
}

main "$@"
