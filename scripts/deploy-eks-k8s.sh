#!/usr/bin/env bash
# Deploy FinCorp K8s manifests to an existing EKS cluster.
# Does NOT build/push images - run scripts/push-ecr.sh first if needed.
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-1}"
CLUSTER_NAME="${CLUSTER_NAME:-fincorp}"
NAMESPACE="${NAMESPACE:-fincorp}"

BACKEND_REPO="${BACKEND_REPO:-fincorp/backend}"
FRONTEND_REPO="${FRONTEND_REPO:-fincorp/frontend}"
IMAGE_TAG="${IMAGE_TAG:-}"
ACCOUNT_ID="${ACCOUNT_ID:-}"

RDS_SECRET_ID="${RDS_SECRET_ID:-fincorp/rds/credentials}"
REDIS_SECRET_ID="${REDIS_SECRET_ID:-fincorp/redis/credentials}"
SKIP_SECRET="${SKIP_SECRET:-0}"
INCLUDE_INGRESS="${INCLUDE_INGRESS:-1}"

usage() {
  cat <<'EOF'
Usage: scripts/deploy-eks-k8s.sh [options]

Applies the k8s/ manifests to an EKS cluster. Does not build or push images -
run scripts/push-ecr.sh first if you need to ship new image bytes.

Options:
  --region <aws-region>         AWS region (default: eu-west-1)
  --cluster <cluster-name>      EKS cluster name (default: fincorp)
  --namespace <namespace>       Kubernetes namespace (default: fincorp)
  --image-tag <tag>             If set, run `kubectl set image` to override
                                the tag in the running Deployments (handy when
                                push-ecr.sh just produced a fresh timestamp tag)
  --account-id <id>             AWS account ID for image URI (default: auto-detect)
  --rds-secret-id <id>          Secrets Manager ID for Postgres creds
  --redis-secret-id <id>        Secrets Manager ID for Redis creds
  --skip-secret                 Skip creating/updating the fincorp-db Secret
  --include-ingress             Also apply k8s/06-ingress.yaml
  -h, --help                    Show this help

Environment variable equivalents:
  AWS_REGION, CLUSTER_NAME, NAMESPACE, IMAGE_TAG, ACCOUNT_ID,
  RDS_SECRET_ID, REDIS_SECRET_ID, SKIP_SECRET=1, INCLUDE_INGRESS=1

Examples:
  scripts/deploy-eks-k8s.sh
  scripts/deploy-eks-k8s.sh --image-tag backend-20260517T162305Z-90273d65
  scripts/deploy-eks-k8s.sh --include-ingress --skip-secret
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

  # Build the DSN/URL in-script and URL-encode credentials so special chars
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

  local redis_url
  redis_url="$(aws secretsmanager get-secret-value \
    --secret-id "$REDIS_SECRET_ID" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text | python3 -c '
import json, sys
from urllib.parse import quote
d = json.load(sys.stdin)
token = quote(d["auth_token"], safe="")
host  = d["host"]
port  = d.get("port", 6379)
print(f"rediss://default:{token}@{host}:{port}/0")
')"

  kubectl -n "$namespace" create secret generic fincorp-db \
    --from-literal=POSTGRES_DSN="$pg_dsn" \
    --from-literal=REDIS_URL="$redis_url" \
    --dry-run=client -o yaml | kubectl apply -f -
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
  role_arn="$(aws iam get-role --role-name "$role_name" \
    --query 'Role.Arn' --output text 2>/dev/null || true)"

  if [[ -z "$role_arn" || "$role_arn" == "None" ]]; then
    echo "IRSA role '$role_name' not found - run \`terraform apply\` in infra/live-eks first." >&2
    exit 1
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
      --redis-secret-id)
        REDIS_SECRET_ID="$2"
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

  echo "Region:       $AWS_REGION"
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

  echo "Applying deployments and services..."
  kubectl apply -f "$k8s_dir/02-backend-deployment.yaml"
  kubectl apply -f "$k8s_dir/03-backend-service.yaml"
  kubectl apply -f "$k8s_dir/04-frontend-deployment.yaml"
  kubectl apply -f "$k8s_dir/05-frontend-service.yaml"

  if [[ -n "$IMAGE_TAG" ]]; then
    local backend_image frontend_image
    backend_image="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$BACKEND_REPO:$IMAGE_TAG"
    frontend_image="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$FRONTEND_REPO:$IMAGE_TAG"

    echo "Updating deployment images to tag: $IMAGE_TAG"
    kubectl -n "$NAMESPACE" set image deployment/backend "backend=$backend_image"
    kubectl -n "$NAMESPACE" set image deployment/frontend "frontend=$frontend_image"
  fi

  if bool_true "$INCLUDE_INGRESS"; then
    ensure_lb_controller
    echo "Applying ingress manifest..."
    kubectl apply -f "$k8s_dir/06-ingress.yaml"
  fi

  echo "Waiting for rollouts..."
  kubectl -n "$NAMESPACE" rollout status deployment/backend
  kubectl -n "$NAMESPACE" rollout status deployment/frontend

  echo "Deployment complete. Current resources:"
  kubectl -n "$NAMESPACE" get pods,svc,ingress

  echo "Tip: If frontend service is LoadBalancer or ingress is enabled, run:"
  echo "  kubectl -n $NAMESPACE get svc frontend"
  echo "  kubectl -n $NAMESPACE get ingress"
}

main "$@"
