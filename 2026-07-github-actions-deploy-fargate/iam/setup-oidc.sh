#!/usr/bin/env bash
#
# setup-oidc.sh — One-time setup so GitHub Actions can deploy to AWS WITHOUT any
# stored access key. Creates:
#   1. The GitHub Actions OIDC identity provider in IAM (idempotent, account-wide).
#   2. A deploy role whose trust policy is LOCKED to one repo + the main branch.
#   3. A least-privilege permissions policy (ECR push + ECS deploy + PassRole only).
#
# Run this ONCE. It prints the role ARN — set it as the GitHub repo secret
# AWS_DEPLOY_ROLE_ARN. Re-running is safe (idempotent).
#
set -Eeuo pipefail

# ---- Config (override via env) ---------------------------------------------
REGION="${REGION:-ap-southeast-1}"
ROLE_NAME="${ROLE_NAME:-hello-fargate-deploy-role}"
POLICY_NAME="${POLICY_NAME:-hello-fargate-deploy-policy}"
# The repo allowed to assume the role. CHANGE THIS to your repo before running.
GH_ORG="${GH_ORG:-culiops}"
GH_REPO="${GH_REPO:-culiops-101}"
OIDC_HOST="token.actions.githubusercontent.com"
# AWS validates the GitHub provider against its own trusted CA store, so this
# thumbprint is effectively ignored for this well-known issuer — but the CLI still
# requires the parameter. This is GitHub's documented value.
THUMBPRINT="${THUMBPRINT:-1b511abead59c6ce207077c0bf0e0043b1382612}"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
info() { echo "${GREEN}==>${RESET} $*"; }
warn() { echo "${YELLOW}!! ${RESET} $*"; }
die()  { echo "${RED}xx ${RESET} $*" >&2; exit 1; }

usage() {
  cat <<EOF
${BOLD}setup-oidc.sh${RESET} — create the GitHub OIDC provider + branch-scoped deploy role

Usage: GH_ORG=youracct GH_REPO=yourrepo ./setup-oidc.sh [--help]

Env overrides:
  REGION       AWS region                (default: ap-southeast-1)
  GH_ORG       GitHub org/user           (default: culiops)
  GH_REPO      GitHub repo name          (default: culiops-101)
  ROLE_NAME    IAM role name             (default: hello-fargate-deploy-role)
  POLICY_NAME  Inline policy name        (default: hello-fargate-deploy-policy)

Prereq: AWS CLI v2 configured with rights to manage IAM (aws sts get-caller-identity works).
EOF
}
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

command -v aws >/dev/null || die "aws CLI not found"
command -v jq  >/dev/null || die "jq not found (needed to template the policies)"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "AWS CLI not configured — run 'aws configure' first"
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

info "Account: ${ACCOUNT_ID} | Region: ${REGION}"
info "Locking deploy role trust to: repo:${GH_ORG}/${GH_REPO}:ref:refs/heads/main"

# ---- 1. OIDC identity provider (idempotent, account-wide) -------------------
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${PROVIDER_ARN}" >/dev/null 2>&1; then
  info "OIDC provider already exists (shared account-wide): ${PROVIDER_ARN}"
else
  info "Creating OIDC provider for ${OIDC_HOST}..."
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${THUMBPRINT}" >/dev/null
fi

# ---- 2. Deploy role with a branch-scoped trust policy ----------------------
TRUST="$(sed -e "s|__ACCOUNT_ID__|${ACCOUNT_ID}|g" \
             -e "s|__GH_ORG__|${GH_ORG}|g" \
             -e "s|__GH_REPO__|${GH_REPO}|g" \
             "${HERE}/github-oidc-trust-policy.json")"

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  info "Role '${ROLE_NAME}' exists — refreshing its trust policy..."
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" \
    --policy-document "${TRUST}" >/dev/null
else
  info "Creating role '${ROLE_NAME}'..."
  aws iam create-role --role-name "${ROLE_NAME}" \
    --description "GitHub Actions deploy role (OIDC, branch-scoped) - CuliOps lab" \
    --assume-role-policy-document "${TRUST}" >/dev/null
fi

# ---- 3. Least-privilege permissions (inline policy) ------------------------
PERMS="$(sed -e "s|__ACCOUNT_ID__|${ACCOUNT_ID}|g" \
             -e "s|__REGION__|${REGION}|g" \
             "${HERE}/deploy-role-permissions.json")"
info "Attaching least-privilege inline policy '${POLICY_NAME}'..."
aws iam put-role-policy --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "${PERMS}" >/dev/null

ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text)"

echo
info "${BOLD}Done.${RESET} Deploy role ARN:"
echo "    ${ROLE_ARN}"
echo
info "Set it as a GitHub repo secret so the workflow can find it:"
echo "    gh secret set AWS_DEPLOY_ROLE_ARN --body '${ROLE_ARN}' --repo ${GH_ORG}/${GH_REPO}"
echo
warn "The trust policy only allows ${GH_ORG}/${GH_REPO} on branch main. Other repos/branches cannot assume this role."
