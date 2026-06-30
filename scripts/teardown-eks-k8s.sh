#!/usr/bin/env bash
set -euo pipefail

# Tear down FinCorp Kubernetes resources from EKS using AWS CLI + kubectl.

AWS_REGION="${AWS_REGION:-eu-west-1}"
CLUSTER_NAME="${CLUSTER_NAME:-fincorp}"
NAMESPACE="${NAMESPACE:-fincorp}"
DELETE_NAMESPACE="${DELETE_NAMESPACE:-0}"
INCLUDE_INGRESS="${INCLUDE_INGRESS:-0}"
REMOVE_LB_CONTROLLER="${REMOVE_LB_CONTROLLER:-0}"
ALB_CLEANUP_WAIT_SECONDS="${ALB_CLEANUP_WAIT_SECONDS:-30}"

usage() {
  cat <<'EOF'
Usage: scripts/teardown-eks-k8s.sh [options]

Options:
  --region <aws-region>         AWS region (default: eu-west-1)
  --cluster <cluster-name>      EKS cluster name (default: fincorp)
  --namespace <namespace>       Kubernetes namespace (default: fincorp)
  --delete-namespace            Delete the whole namespace at the end
  --include-ingress             Delete k8s/06-ingress.yaml first (so the LB Controller
                                tears down the ALB cleanly)
  --remove-lb-controller        Also `helm uninstall` the AWS Load Balancer Controller
                                and remove its CRDs from kube-system
  -h, --help                    Show this help

Environment variable alternatives:
  AWS_REGION, CLUSTER_NAME, NAMESPACE,
  DELETE_NAMESPACE=1, INCLUDE_INGRESS=1, REMOVE_LB_CONTROLLER=1

Examples:
  scripts/teardown-eks-k8s.sh --include-ingress --delete-namespace
  scripts/teardown-eks-k8s.sh --include-ingress --delete-namespace --remove-lb-controller
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
      --delete-namespace)
        DELETE_NAMESPACE="1"
        shift
        ;;
      --include-ingress)
        INCLUDE_INGRESS="1"
        shift
        ;;
      --remove-lb-controller)
        REMOVE_LB_CONTROLLER="1"
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

  local root k8s_dir
  root="$(repo_root)"
  k8s_dir="$root/k8s"

  [[ -d "$k8s_dir" ]] || {
    echo "k8s directory not found: $k8s_dir" >&2
    exit 1
  }

  echo "Region:       $AWS_REGION"
  echo "Cluster:      $CLUSTER_NAME"
  echo "Namespace:    $NAMESPACE"
  echo "K8s dir:      $k8s_dir"

  echo "Updating kubeconfig for EKS cluster..."
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

  if bool_true "$INCLUDE_INGRESS"; then
    echo "Deleting ingress (this also triggers the LB Controller to delete the ALB)..."
    kubectl delete -f "$k8s_dir/06-ingress.yaml" --ignore-not-found=true
    echo "Waiting ${ALB_CLEANUP_WAIT_SECONDS}s for the ALB cleanup to complete..."
    sleep "$ALB_CLEANUP_WAIT_SECONDS"
  fi

  echo "Deleting frontend/backend services and deployments..."
  kubectl delete -f "$k8s_dir/05-frontend-service.yaml" --ignore-not-found=true
  kubectl delete -f "$k8s_dir/04-frontend-deployment.yaml" --ignore-not-found=true
  kubectl delete -f "$k8s_dir/03-backend-service.yaml" --ignore-not-found=true
  kubectl delete -f "$k8s_dir/02-backend-deployment.yaml" --ignore-not-found=true

  echo "Deleting configmap and secret..."
  kubectl -n "$NAMESPACE" delete configmap fincorp-app --ignore-not-found=true
  kubectl -n "$NAMESPACE" delete secret fincorp-db --ignore-not-found=true

  if bool_true "$DELETE_NAMESPACE"; then
    echo "Deleting namespace: $NAMESPACE"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
  else
    echo "Keeping namespace $NAMESPACE (use --delete-namespace to remove it)."
  fi

  if bool_true "$REMOVE_LB_CONTROLLER"; then
    need_cmd helm
    echo "Uninstalling AWS Load Balancer Controller (Helm)..."
    helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null \
      || echo "  (release not found - already uninstalled)"

    echo "Removing LB Controller CRDs..."
    kubectl delete crd targetgroupbindings.elbv2.k8s.aws --ignore-not-found=true
    kubectl delete crd ingressclassparams.elbv2.k8s.aws --ignore-not-found=true
  else
    echo "Keeping AWS Load Balancer Controller (use --remove-lb-controller to uninstall)."
  fi

  echo "Teardown complete. Remaining resources in namespace (if it still exists):"
  kubectl -n "$NAMESPACE" get all 2>/dev/null || true
}

main "$@"
