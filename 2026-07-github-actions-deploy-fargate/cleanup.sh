#!/usr/bin/env bash
#
# cleanup.sh — CuliOps Lab Cleanup (GitHub Actions → OIDC → ECS Fargate)
# ⚠️  Deletes EVERYTHING the bootstrap + OIDC setup created. Run when you are done.
#
# The account-wide OIDC provider is NOT deleted by default (other repos/roles may
# use it). Pass DELETE_OIDC_PROVIDER=true to remove it too.
#
set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
ECR_REPO="${ECR_REPO:-hello-fargate}"
CLUSTER="${CLUSTER:-hello-fargate-cluster}"
SERVICE="${SERVICE:-hello-fargate-svc}"
FAMILY="${FAMILY:-hello-fargate}"
LOG_GROUP="${LOG_GROUP:-/ecs/hello-fargate}"
EXEC_ROLE="${EXEC_ROLE:-hello-fargate-exec-role}"
TASK_ROLE="${TASK_ROLE:-hello-fargate-task-role}"
SG_NAME="${SG_NAME:-hello-fargate-sg}"
# CI/CD-specific:
DEPLOY_ROLE="${DEPLOY_ROLE:-hello-fargate-deploy-role}"
DEPLOY_POLICY="${DEPLOY_POLICY:-hello-fargate-deploy-policy}"
DELETE_OIDC_PROVIDER="${DELETE_OIDC_PROVIDER:-false}"
OIDC_HOST="token.actions.githubusercontent.com"

GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
info() { echo "${GREEN}==>${RESET} $*"; }
warn() { echo "${YELLOW}!! ${RESET} $*"; }
# Never let a missing resource abort cleanup.
ok()   { "$@" 2>/dev/null || true; }

echo "${BOLD}🧹 CuliOps Lab Cleanup — GitHub Actions → OIDC → Fargate${RESET}"
echo "========================================================"
echo "This will delete (in ${REGION}):"
echo "  - ECS service:        ${SERVICE}"
echo "  - ECS cluster:        ${CLUSTER}"
echo "  - Task definitions:   ${FAMILY}:* (deregistered)"
echo "  - ECR repo + images:  ${ECR_REPO}"
echo "  - Security group:     ${SG_NAME}"
echo "  - Log group:          ${LOG_GROUP}"
echo "  - IAM roles:          ${EXEC_ROLE}, ${TASK_ROLE}, ${DEPLOY_ROLE}"
if [[ "${DELETE_OIDC_PROVIDER}" == "true" ]]; then
echo "  - OIDC provider:      ${OIDC_HOST}  ${YELLOW}(account-wide!)${RESET}"
else
echo "  - OIDC provider:      KEPT (set DELETE_OIDC_PROVIDER=true to remove)"
fi
echo
read -r -p "Continue? (y/N) " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# 1. Service first (most dependent). Scale to 0, then delete --force.
info "Deleting service..."
ok aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" --desired-count 0 --region "${REGION}" >/dev/null
ok aws ecs delete-service --cluster "${CLUSTER}" --service "${SERVICE}" --force --region "${REGION}" >/dev/null
ok aws ecs wait services-inactive --cluster "${CLUSTER}" --services "${SERVICE}" --region "${REGION}"

# 2. Deregister every task-def revision in the family.
info "Deregistering task definitions..."
for arn in $(aws ecs list-task-definitions --family-prefix "${FAMILY}" --region "${REGION}" \
              --query 'taskDefinitionArns[]' --output text 2>/dev/null || true); do
  ok aws ecs deregister-task-definition --task-definition "${arn}" --region "${REGION}" >/dev/null
done

# 3. Cluster.
info "Deleting cluster..."
ok aws ecs delete-cluster --cluster "${CLUSTER}" --region "${REGION}" >/dev/null

# 4. ECR repo (force removes images too).
info "Deleting ECR repo + images..."
ok aws ecr delete-repository --repository-name "${ECR_REPO}" --force --region "${REGION}" >/dev/null

# 5. Security group (only deletable once the ENIs are gone — give it a moment).
info "Deleting security group..."
SG_ID="$(aws ec2 describe-security-groups --filters Name=group-name,Values="${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text --region "${REGION}" 2>/dev/null || echo None)"
SG_LEFT=""
if [[ "${SG_ID}" != "None" && -n "${SG_ID}" ]]; then
  SG_LEFT="${SG_ID}"
  for _ in 1 2 3 4 5; do
    if aws ec2 delete-security-group --group-id "${SG_ID}" --region "${REGION}" >/dev/null 2>&1; then SG_LEFT=""; break; fi
    warn "SG still attached (ENI draining), retrying in 15s..."
    sleep 15
  done
fi

# 6. Log group.
info "Deleting log group..."
ok aws logs delete-log-group --log-group-name "${LOG_GROUP}" --region "${REGION}"

# 7. IAM roles (detach/delete inline policies first).
info "Deleting IAM roles..."
ok aws iam detach-role-policy --role-name "${EXEC_ROLE}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
ok aws iam delete-role --role-name "${EXEC_ROLE}"
ok aws iam delete-role --role-name "${TASK_ROLE}"
# Deploy role carries an INLINE policy — delete it before the role.
ok aws iam delete-role-policy --role-name "${DEPLOY_ROLE}" --policy-name "${DEPLOY_POLICY}"
ok aws iam delete-role --role-name "${DEPLOY_ROLE}"

# 8. OIDC provider — account-wide, opt-in only.
if [[ "${DELETE_OIDC_PROVIDER}" == "true" ]]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '')"
  if [[ -n "${ACCOUNT_ID}" ]]; then
    info "Deleting OIDC provider (account-wide)..."
    ok aws iam delete-open-id-connect-provider \
      --open-id-connect-provider-arn "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
  fi
else
  warn "OIDC provider kept (shared account-wide). DELETE_OIDC_PROVIDER=true ./cleanup.sh to remove it."
fi

echo
if [[ -n "${SG_LEFT}" ]]; then
  warn "${BOLD}Done — 1 leftover:${RESET} security group ${SG_LEFT} (ENI still draining). Re-run ./cleanup.sh in a minute."
else
  info "${BOLD}✅ Cleanup complete!${RESET}"
fi
echo "💰 Estimated savings: ~\$0.35/day (Fargate 0.25 vCPU / 0.5 GB, 24/7, ap-southeast-1)."
echo
echo "Double-check in the AWS Console (region ${REGION}):"
echo "  - ECS > Clusters          (no ${CLUSTER})"
echo "  - ECR > Repositories      (no ${ECR_REPO})"
echo "  - EC2 > Security Groups   (no ${SG_NAME})"
echo "  - CloudWatch > Log groups (no ${LOG_GROUP})"
echo "  - IAM > Roles             (no ${DEPLOY_ROLE})"
