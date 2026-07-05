#!/usr/bin/env bash
#
# 02-deploy-fargate.sh — Stand up IAM roles, a cluster, a task def, and a
# service on Fargate, then print the public URL.
#
# Run 01-build-and-push.sh FIRST. Run cleanup.sh when you are done (costs money).
#
set -Eeuo pipefail

# ---- Config (override via env) ---------------------------------------------
REGION="${REGION:-ap-southeast-1}"
ECR_REPO="${ECR_REPO:-hello-fargate}"
IMAGE_TAG="${IMAGE_TAG:-v1.0.0}"
CLUSTER="${CLUSTER:-hello-fargate-cluster}"
SERVICE="${SERVICE:-hello-fargate-svc}"
FAMILY="${FAMILY:-hello-fargate}"
LOG_GROUP="${LOG_GROUP:-/ecs/hello-fargate}"
CONTAINER_PORT="${CONTAINER_PORT:-3000}"
# Demo-specific role names so cleanup.sh can safely delete them without
# touching a shared 'ecsTaskExecutionRole' your other projects might use.
EXEC_ROLE="${EXEC_ROLE:-hello-fargate-exec-role}"
TASK_ROLE="${TASK_ROLE:-hello-fargate-task-role}"
SG_NAME="${SG_NAME:-hello-fargate-sg}"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
info() { echo "${GREEN}==>${RESET} $*"; }
warn() { echo "${YELLOW}!! ${RESET} $*"; }
die()  { echo "${RED}xx ${RESET} $*" >&2; exit 1; }

usage() {
  cat <<EOF
${BOLD}02-deploy-fargate.sh${RESET} — deploy the pushed image to ECS Fargate

Usage: ./02-deploy-fargate.sh [--help]

Uses the default VPC + a public subnet + assignPublicIp=ENABLED so we avoid a
NAT Gateway. For a real service you would put tasks in PRIVATE subnets behind an
ALB — that is a separate video.
EOF
}
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

command -v aws >/dev/null || die "aws CLI not found"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || die "AWS CLI not configured"
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

info "Account: ${ACCOUNT_ID} | Region: ${REGION} | Image: ${IMAGE_URI}"

# ---- Failure diagnostics ---------------------------------------------------
# If anything below fails (most often: the task won't start and services-stable
# times out), don't die silently on a half-built, BILLING stack. Print WHY the
# task stopped — stoppedReason is exactly how you debug scars #1, #2 and #4.
RENDERED=""
on_error() {
  local ec=$?
  echo
  warn "Deploy failed (exit ${ec})."
  local t
  t="$(aws ecs list-tasks --cluster "${CLUSTER}" --service-name "${SERVICE}" \
        --desired-status STOPPED --region "${REGION}" --query 'taskArns[0]' --output text 2>/dev/null || true)"
  [[ -z "${t}" || "${t}" == "None" ]] && t="$(aws ecs list-tasks --cluster "${CLUSTER}" \
        --service-name "${SERVICE}" --region "${REGION}" --query 'taskArns[0]' --output text 2>/dev/null || true)"
  if [[ -n "${t}" && "${t}" != "None" ]]; then
    warn "Why the task stopped:"
    aws ecs describe-tasks --cluster "${CLUSTER}" --tasks "${t}" --region "${REGION}" \
      --query 'tasks[0].{stopCode:stopCode,stoppedReason:stoppedReason,containers:containers[].{name:name,reason:reason,exitCode:exitCode}}' \
      --output table 2>/dev/null || true
  fi
  warn "Resources may be partially created and BILLING — tear down with: ./cleanup.sh"
  [[ -n "${RENDERED}" ]] && rm -f "${RENDERED}"
  exit "${ec}"
}
trap on_error ERR

# ---- 1. IAM roles ----------------------------------------------------------
# EXECUTION role = for the ECS agent/platform: pull the image, write logs.
# TASK role      = for YOUR application code: call S3 / SQS / Secrets Manager.
# Swap them and you get "CannotPullContainerError" or your app loses AWS access.
# (Scar #2 in the video.)
ensure_role() {
  local name="$1"
  if aws iam get-role --role-name "${name}" >/dev/null 2>&1; then
    info "IAM role '${name}' already exists."
  else
    info "Creating IAM role '${name}'..."
    aws iam create-role --role-name "${name}" \
      --assume-role-policy-document "${TRUST}" >/dev/null
  fi
}
ensure_role "${EXEC_ROLE}"
aws iam attach-role-policy --role-name "${EXEC_ROLE}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
ensure_role "${TASK_ROLE}"  # left empty on purpose — hello-world calls no AWS APIs

EXEC_ROLE_ARN="$(aws iam get-role --role-name "${EXEC_ROLE}" --query Role.Arn --output text)"
TASK_ROLE_ARN="$(aws iam get-role --role-name "${TASK_ROLE}" --query Role.Arn --output text)"

# ---- 2. CloudWatch log group -----------------------------------------------
if ! aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" --region "${REGION}" \
      --query "logGroups[?logGroupName=='${LOG_GROUP}']" --output text | grep -q "${LOG_GROUP}"; then
  info "Creating log group '${LOG_GROUP}'..."
  aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${REGION}"
else
  info "Log group '${LOG_GROUP}' already exists."
fi

# ---- 3. Default VPC, a subnet, and a security group ------------------------
# Networking: a public subnet in the default VPC. Many accounts (hardened /
# org-managed) have NO default VPC — set SUBNET_ID to any public subnet to run
# there; the VPC is derived from it.
if [[ -n "${SUBNET_ID:-}" ]]; then
  VPC_ID="$(aws ec2 describe-subnets --subnet-ids "${SUBNET_ID}" \
    --query 'Subnets[0].VpcId' --output text --region "${REGION}" 2>/dev/null)" \
    || die "SUBNET_ID='${SUBNET_ID}' not found in ${REGION}."
  info "Using provided subnet ${SUBNET_ID} (VPC ${VPC_ID})."
else
  VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text --region "${REGION}")"
  [[ "${VPC_ID}" != "None" ]] || die "No default VPC in ${REGION}. Either create one:
    aws ec2 create-default-vpc --region ${REGION}
  or point at an existing public subnet and re-run:
    SUBNET_ID=subnet-xxxxxxxx ./02-deploy-fargate.sh"
  SUBNET_ID="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="${VPC_ID}" \
    Name=map-public-ip-on-launch,Values=true \
    --query 'Subnets[0].SubnetId' --output text --region "${REGION}")"
  [[ "${SUBNET_ID}" != "None" ]] || die "Default VPC ${VPC_ID} has no public subnet — set SUBNET_ID=<public-subnet> manually."
fi
info "VPC: ${VPC_ID} | Subnet: ${SUBNET_ID}"

SG_ID="$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="${SG_NAME}" Name=vpc-id,Values="${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text --region "${REGION}" 2>/dev/null || echo None)"
if [[ "${SG_ID}" == "None" || -z "${SG_ID}" ]]; then
  info "Creating security group '${SG_NAME}'..."
  SG_ID="$(aws ec2 create-security-group --group-name "${SG_NAME}" \
    --description "hello-fargate demo" --vpc-id "${VPC_ID}" \
    --query GroupId --output text --region "${REGION}")"
  # Open the app port. If you forget this, the task runs but nobody can reach it.
  # (Scar #4 in the video.)
  aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
    --protocol tcp --port "${CONTAINER_PORT}" --cidr 0.0.0.0/0 --region "${REGION}" >/dev/null
else
  info "Security group '${SG_NAME}' already exists: ${SG_ID}"
fi

# ---- 4. Render + register the task definition ------------------------------
info "Registering task definition..."
RENDERED="$(mktemp)"
sed -e "s|__EXECUTION_ROLE_ARN__|${EXEC_ROLE_ARN}|g" \
    -e "s|__TASK_ROLE_ARN__|${TASK_ROLE_ARN}|g" \
    -e "s|__IMAGE_URI__|${IMAGE_URI}|g" \
    -e "s|__IMAGE_TAG__|${IMAGE_TAG}|g" \
    -e "s|__REGION__|${REGION}|g" \
    task-definition.json > "${RENDERED}"
# New roles can take a few seconds to be assumable by ECS.
sleep 8
TASK_DEF_ARN="$(aws ecs register-task-definition --cli-input-json "file://${RENDERED}" \
  --region "${REGION}" --query 'taskDefinition.taskDefinitionArn' --output text)"
rm -f "${RENDERED}"
info "Task definition: ${TASK_DEF_ARN}"

# ---- 5. Cluster ------------------------------------------------------------
# Exact-match the status — a soft-deleted cluster reports "INACTIVE", which
# *contains* "ACTIVE", so `grep -q ACTIVE` would wrongly skip re-creation.
CLUSTER_STATUS="$(aws ecs describe-clusters --clusters "${CLUSTER}" --region "${REGION}" \
  --query 'clusters[0].status' --output text 2>/dev/null || echo NONE)"
if [[ "${CLUSTER_STATUS}" != "ACTIVE" ]]; then
  info "Creating cluster '${CLUSTER}'..."
  aws ecs create-cluster --cluster-name "${CLUSTER}" --region "${REGION}" >/dev/null
else
  info "Cluster '${CLUSTER}' already active."
fi

# ---- 6. Service (create or update) -----------------------------------------
# Exact-match again: a deleted service is "INACTIVE" (contains "ACTIVE") — only
# UPDATE an ACTIVE one; anything else (INACTIVE / DRAINING / missing) → create.
NET_CONFIG="awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}"
SVC_STATUS="$(aws ecs describe-services --cluster "${CLUSTER}" --services "${SERVICE}" --region "${REGION}" \
  --query 'services[0].status' --output text 2>/dev/null || echo NONE)"
if [[ "${SVC_STATUS}" == "ACTIVE" ]]; then
  info "Updating existing service '${SERVICE}'..."
  aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" \
    --task-definition "${TASK_DEF_ARN}" --platform-version LATEST \
    --region "${REGION}" >/dev/null
else
  info "Creating service '${SERVICE}'..."
  aws ecs create-service \
    --cluster "${CLUSTER}" --service-name "${SERVICE}" \
    --task-definition "${TASK_DEF_ARN}" --desired-count 1 \
    --launch-type FARGATE --platform-version LATEST \
    --network-configuration "${NET_CONFIG}" \
    --region "${REGION}" >/dev/null
fi

info "Waiting for the service to stabilize (this takes 1-3 min)..."
aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}" --region "${REGION}"

# ---- 7. Find the task's public IP ------------------------------------------
TASK_ARN="$(aws ecs list-tasks --cluster "${CLUSTER}" --service-name "${SERVICE}" \
  --region "${REGION}" --query 'taskArns[0]' --output text)"
ENI_ID="$(aws ecs describe-tasks --cluster "${CLUSTER}" --tasks "${TASK_ARN}" --region "${REGION}" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text)"
PUBLIC_IP="$(aws ec2 describe-network-interfaces --network-interface-ids "${ENI_ID}" --region "${REGION}" \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)"

echo
info "${BOLD}It is live:${RESET} http://${PUBLIC_IP}:${CONTAINER_PORT}/"
info "Health:        http://${PUBLIC_IP}:${CONTAINER_PORT}/health"
info "Logs:          aws logs tail ${LOG_GROUP} --follow --region ${REGION}"
warn "This is costing money. Run ./cleanup.sh when you are done."
