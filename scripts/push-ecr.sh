#!/usr/bin/env bash
set -euo pipefail

# ---- Configuration (edit these) --------------------------------------------
AWS_REGION="${AWS_REGION:-eu-west-1}"

# ECR repositories (name only, without the registry prefix)
BACKEND_REPO="${BACKEND_REPO:-fincorp/backend}"
FRONTEND_REPO="${FRONTEND_REPO:-fincorp/frontend}"

# Tags
# - If TAG is set, it will be used for both images.
# - Otherwise each image gets its own tag (defaults to timestamp + random suffix).
TAG="${TAG:-}"
BACKEND_TAG="${BACKEND_TAG:-}"
FRONTEND_TAG="${FRONTEND_TAG:-}"

# Build platform (important on Apple Silicon; Fargate is usually x86_64)
PLATFORM="${PLATFORM:-linux/amd64}"

# Paths (relative to repo root)
BACKEND_DIR="${BACKEND_DIR:-backend}"
FRONTEND_DIR="${FRONTEND_DIR:-frontend}"
# ---------------------------------------------------------------------------

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

aws_account_id() {
  aws sts get-caller-identity --query Account --output text
}

ensure_repo() {
  local repo_name="$1"
  if ! aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$repo_name" >/dev/null 2>&1; then
    echo "ECR repo '$repo_name' not found; creating (IMMUTABLE tags)..."
    aws ecr create-repository \
      --region "$AWS_REGION" \
      --repository-name "$repo_name" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability IMMUTABLE \
      >/dev/null
  fi

  # Enforce immutability even if the repo already existed.
  aws ecr put-image-tag-mutability \
    --region "$AWS_REGION" \
    --repository-name "$repo_name" \
    --image-tag-mutability IMMUTABLE \
    >/dev/null

  # Enforce scan-on-push even if the repo already existed.
  aws ecr put-image-scanning-configuration \
    --region "$AWS_REGION" \
    --repository-name "$repo_name" \
    --image-scanning-configuration scanOnPush=true \
    >/dev/null
}

random_tag_suffix() {
  # 8 chars of lowercase hex (safe for Docker tags).
  # Use openssl to avoid SIGPIPE issues under `set -o pipefail`.
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4
    return
  fi

  # Fallback: python (present on most dev machines)
  python3 - <<'PY'
import secrets
print(secrets.token_hex(4))
PY
}

main() {
  need_cmd aws
  need_cmd docker

  local root
  root="$(repo_root)"

  if [[ -z "$TAG" ]]; then
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    BACKEND_TAG="${BACKEND_TAG:-backend-${ts}-$(random_tag_suffix)}"
    FRONTEND_TAG="${FRONTEND_TAG:-frontend-${ts}-$(random_tag_suffix)}"
  else
    BACKEND_TAG="$TAG"
    FRONTEND_TAG="$TAG"
  fi

  local account_id registry
  account_id="$(aws_account_id)"
  registry="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  echo "Using registry: $registry"
  echo "Backend:  ${BACKEND_REPO}:${BACKEND_TAG}"
  echo "Frontend: ${FRONTEND_REPO}:${FRONTEND_TAG}"

  echo "Ensuring repositories exist..."
  ensure_repo "$BACKEND_REPO"
  ensure_repo "$FRONTEND_REPO"

  echo "Logging Docker into ECR..."
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$registry" >/dev/null

  echo "Building backend ($PLATFORM) and pushing..."
  docker build --platform="$PLATFORM" -t "$registry/$BACKEND_REPO:$BACKEND_TAG" "$root/$BACKEND_DIR"
  docker push "$registry/$BACKEND_REPO:$BACKEND_TAG"

  echo "Building frontend ($PLATFORM) and pushing..."
  docker build --platform="$PLATFORM" -t "$registry/$FRONTEND_REPO:$FRONTEND_TAG" "$root/$FRONTEND_DIR"
  docker push "$registry/$FRONTEND_REPO:$FRONTEND_TAG"

  echo "Done. Image URIs:"
  echo "- $registry/$BACKEND_REPO:$BACKEND_TAG"
  echo "- $registry/$FRONTEND_REPO:$FRONTEND_TAG"
}

main "$@"
