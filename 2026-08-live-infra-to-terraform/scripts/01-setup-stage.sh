#!/usr/bin/env bash
# 01-setup-stage.sh — adopt-clickops-ec2 / stage setup (OFF-CAMERA)
#
# Creates the "pre-existing environment" this lab adopts: a minimal VPC +
# the legacy EC2 instance + its Security Group + a read-only IAM identity
# for the agent — then removes the instance and SG from Terraform state so
# they become genuinely UNMANAGED, an honest stand-in for click-ops infra.
#
# This step is NOT the demo. It's the precondition the demo needs to exist
# before an agent can "discover" anything. Run it once before recording /
# working through the adopt/ steps in ../README.md.
#
# Usage:
#   ./01-setup-stage.sh                    # uses AWS_PROFILE/AWS_REGION from env or .env
#   ./01-setup-stage.sh --profile sandbox-admin --region ap-southeast-1
#   ./01-setup-stage.sh --help
#
# Requires:
#   - Terraform >= 1.5
#   - AWS credentials with permission to create VPC/EC2/IAM (sandbox-admin —
#     creating IAM resources needs admin, not the lab's own read-only agent
#     profile)

set -Eeuo pipefail

# ─── Color output ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

on_error() {
  local exit_code=$?
  log_error "Setup failed (exit ${exit_code}) at line ${BASH_LINENO[0]}."
  log_warn "The stage/ Terraform root may be partially applied."
  log_warn "Run ../cleanup.sh to tear down anything that was created before retrying."
  exit "${exit_code}"
}
trap on_error ERR

# ─── Args ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGE_DIR="${LAB_ROOT}/stage"

AWS_PROFILE_ARG=""
AWS_REGION_ARG=""

for arg in "$@"; do
  case "$arg" in
    --profile=*) AWS_PROFILE_ARG="${arg#*=}" ;;
    --profile)   shift; AWS_PROFILE_ARG="${1:-}" ;;
    --region=*)  AWS_REGION_ARG="${arg#*=}" ;;
    --region)    shift; AWS_REGION_ARG="${1:-}" ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) ;;
  esac
  shift || true
done

if [[ -f "${LAB_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${LAB_ROOT}/.env"
fi

export AWS_PROFILE="${AWS_PROFILE_ARG:-${AWS_PROFILE:-sandbox-admin}}"
export AWS_REGION="${AWS_REGION_ARG:-${AWS_REGION:-ap-southeast-1}}"

echo ""
echo -e "${BLUE}=== adopt-clickops-ec2 — stage setup ===${NC}"
log_info "AWS_PROFILE=${AWS_PROFILE}"
log_info "AWS_REGION=${AWS_REGION}"
log_warn "This needs sandbox-admin (or equivalent) — creating VPC/EC2/IAM resources, not just describing them."
echo ""

cd "${STAGE_DIR}"

log_info "terraform init"
terraform init -input=false

log_info "terraform apply (creating VPC, legacy EC2 + SG, agent IAM identity)"
terraform apply -auto-approve -input=false -var="aws_region=${AWS_REGION}"

echo ""
log_info "Reading back resource ids before making them unmanaged..."
INSTANCE_ID="$(terraform output -raw legacy_instance_id)"
SG_ID="$(terraform output -raw legacy_sg_id)"

# ─── Make the instance + SG genuinely unmanaged ───────────────────────────────
# This is the whole point: after this, nobody's Terraform state tracks these
# two resources. They keep running in AWS exactly like a real click-ops box
# would. stage/ from here on only "owns" the network + IAM plumbing.
log_info "Removing aws_instance.legacy and aws_security_group.legacy from stage state..."
terraform state rm aws_instance.legacy
terraform state rm aws_security_group.legacy
log_success "Instance ${INSTANCE_ID} and SG ${SG_ID} are now unmanaged."

echo ""
log_success "Stage setup complete."
echo ""
echo "Values for adopt/terraform.tfvars (or read them again anytime with"
echo "  cd stage && terraform output"
echo "since the instance/SG stay real AWS resources even after state rm):"
echo ""
terraform output
echo ""
log_warn "Do NOT re-run 'terraform apply' in stage/ after this point — the legacy"
log_warn "instance + SG are intentionally removed from state but still declared in"
log_warn "stage/main.tf, so a re-apply would create a SECOND copy. To tear down, use"
log_warn "../cleanup.sh (it sweeps the unmanaged legacy resources by tag first)."
echo ""
log_warn "Next: cd ../adopt and follow README.md Step 3 onward."
