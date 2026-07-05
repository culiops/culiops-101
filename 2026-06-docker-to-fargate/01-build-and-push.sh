#!/usr/bin/env bash
#
# 01-build-and-push.sh — Build the image for the RIGHT platform and push to ECR.
#
# This is step 1 of 2. Run 02-deploy-fargate.sh afterwards.
#
set -euo pipefail

# ---- Config (override via env) ---------------------------------------------
REGION="${REGION:-ap-southeast-1}"
ECR_REPO="${ECR_REPO:-hello-fargate}"
# IMMUTABLE tag on purpose. Never :latest — "redeploy the old version" must mean
# the SAME bytes, not whatever :latest points at today. (Scar #3 in the video.)
IMAGE_TAG="${IMAGE_TAG:-v1.0.0}"

# ---- Colors ----------------------------------------------------------------
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
info()  { echo "${GREEN}==>${RESET} $*"; }
warn()  { echo "${YELLOW}!! ${RESET} $*"; }
die()   { echo "${RED}xx ${RESET} $*" >&2; exit 1; }

usage() {
  cat <<EOF
${BOLD}01-build-and-push.sh${RESET} — build for linux/amd64 and push to Amazon ECR

Usage: ./01-build-and-push.sh [--help]

Env overrides:
  REGION     AWS region            (default: ap-southeast-1)
  ECR_REPO   ECR repository name    (default: hello-fargate)
  IMAGE_TAG  Immutable image tag    (default: v1.0.0)

Prereqs: Docker running, AWS CLI v2 configured (aws sts get-caller-identity works).
EOF
}
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

command -v docker >/dev/null || die "docker not found"
command -v aws    >/dev/null || die "aws CLI not found"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "AWS CLI not configured — run 'aws configure' first"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
IMAGE_URI="${ECR_URI}:${IMAGE_TAG}"

info "Account: ${ACCOUNT_ID} | Region: ${REGION}"
info "Target image: ${IMAGE_URI}"

# ---- 1. Ensure the ECR repo exists (with scan-on-push) ---------------------
if aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${REGION}" >/dev/null 2>&1; then
  info "ECR repo '${ECR_REPO}' already exists."
else
  info "Creating ECR repo '${ECR_REPO}' (scan-on-push enabled)..."
  aws ecr create-repository \
    --repository-name "${ECR_REPO}" \
    --image-scanning-configuration scanOnPush=true \
    --region "${REGION}" >/dev/null
fi

# ---- 2. Build for the platform Fargate runs (linux/amd64) ------------------
# THE flag. Without it, an M-series Mac builds arm64 and Fargate throws
# "exec format error". (Scar #1 in the video.)
info "Building image for linux/amd64..."
docker build --platform linux/amd64 -t "${ECR_REPO}:${IMAGE_TAG}" .

# ---- 3. Authenticate Docker to ECR -----------------------------------------
info "Logging Docker in to ECR..."
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# ---- 4. Tag + push ----------------------------------------------------------
info "Tagging and pushing..."
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${IMAGE_URI}"
docker push "${IMAGE_URI}"

echo
info "${BOLD}Pushed:${RESET} ${IMAGE_URI}"
info "Next: ./02-deploy-fargate.sh"
