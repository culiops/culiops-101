#!/usr/bin/env bash
# cleanup.sh — adopt-clickops-ec2 Lab Cleanup
#
# WARNING: This script permanently deletes AWS resources created in this lab.
# Run this when you are done to avoid unexpected AWS charges.
#
# Why this script exists alongside `terraform destroy`: this lab is
# deliberately split into TWO Terraform roots (stage/ and adopt/) so
# ownership never overlaps during the demo. That means a plain
# `terraform destroy` in one root isn't enough — this script destroys them
# in the correct, safe order so neither root is left orphaned or fighting
# over a resource the other one thinks it owns.
#
# Usage:
#   ./cleanup.sh              # Interactive — asks for confirmation
#   ./cleanup.sh --yes        # Skip confirmation (use with caution in CI)
#   ./cleanup.sh --dry-run    # Show what would be destroyed without destroying
#   ./cleanup.sh --help       # Show this help message

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
  log_error "cleanup.sh hit an error (exit ${exit_code})."
  log_warn "Some resources may still exist — re-run ./cleanup.sh, or check the AWS Console (URLs at the end of this script's normal output)."
  exit "${exit_code}"
}
trap on_error ERR

# ─── Args ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_DIR="${SCRIPT_DIR}/stage"
ADOPT_DIR="${SCRIPT_DIR}/adopt"

AUTO_YES=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --yes)     AUTO_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      log_error "Unknown argument: $arg"
      exit 1
      ;;
  esac
done

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
fi

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
export AWS_PROFILE="${AWS_PROFILE:-sandbox-admin}"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${RED}╔══════════════════════════════════════════════╗${NC}"
echo -e "${RED}║        CuliOps Lab Cleanup                   ║${NC}"
echo -e "${RED}║  adopt-clickops-ec2                          ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "DRY RUN MODE — no resources will actually be destroyed."
  echo ""
fi

ADOPT_HAS_STATE=false
if [[ -f "${ADOPT_DIR}/terraform.tfstate" ]] || [[ -d "${ADOPT_DIR}/.terraform" ]]; then
  ADOPT_HAS_STATE=true
fi

STAGE_HAS_STATE=false
if [[ -f "${STAGE_DIR}/terraform.tfstate" ]] || [[ -d "${STAGE_DIR}/.terraform" ]]; then
  STAGE_HAS_STATE=true
fi

echo -e "${YELLOW}The following will be PERMANENTLY DESTROYED (in this order):${NC}"
echo ""
echo "  Region: ${AWS_REGION}"
echo ""
if [[ "$ADOPT_HAS_STATE" == "true" ]]; then
  echo "  1. adopt/  — the adopted EC2 instance + Security Group (imported resources)"
else
  echo "  1. adopt/  — no state found, nothing to destroy here (skipping)"
fi
if [[ "$STAGE_HAS_STATE" == "true" ]]; then
  echo "  2. stage/  — VPC, subnet, IGW, route table, agent IAM policy + user"
  echo "               (NOTE: if stage's setup script already ran, the legacy"
  echo "               instance/SG are NOT in stage's state anymore — they were"
  echo "               adopted by adopt/ above, or if you skip step 1, they will"
  echo "               be left running and billable. Always destroy adopt/ first.)"
else
  echo "  2. stage/  — no state found, nothing to destroy here (skipping)"
fi
echo ""

if [[ "$ADOPT_HAS_STATE" != "true" && "$STAGE_HAS_STATE" != "true" ]]; then
  log_warn "No Terraform state found in either root. Nothing to clean up."
  exit 0
fi

# ─── Confirmation ─────────────────────────────────────────────────────────────
if [[ "$AUTO_YES" != "true" && "$DRY_RUN" != "true" ]]; then
  read -r -p "Are you sure you want to destroy all of the above? (y/N) " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_warn "Cleanup cancelled. No resources were destroyed."
    exit 0
  fi
fi

echo ""

# ─── 1. Destroy adopt/ first (the resources it adopted) ──────────────────────
if [[ "$ADOPT_HAS_STATE" == "true" ]]; then
  log_info "Destroying adopt/ (adopted EC2 + SG)..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "[DRY RUN] Would run: terraform -chdir=${ADOPT_DIR} destroy -auto-approve"
  else
    if terraform -chdir="${ADOPT_DIR}" destroy -auto-approve; then
      log_success "adopt/ destroyed."
    else
      log_error "adopt/ destroy failed. Check the output above before proceeding to stage/."
      log_warn "Re-run ./cleanup.sh once fixed — it will pick up where this left off."
      exit 1
    fi
  fi
else
  log_warn "adopt/ has no state — skipping (already destroyed, or setup never got this far)."
fi

echo ""

# ─── 1b. Sweep any UNMANAGED legacy resources (orphan-safe) ──────────────────
# If adopt/ was never completed, the legacy instance + SG are still running,
# unmanaged (setup ran `state rm` on them), and will block stage/'s subnet/VPC
# destroy with a DependencyViolation. Terminate them by THIS lab's tag before
# touching the network. Scoped strictly to Lab=adopt-clickops-ec2 so it can
# never touch anything else in the shared sandbox account.
if [[ "$STAGE_HAS_STATE" == "true" ]]; then
  log_info "Sweeping for unmanaged legacy resources tagged Lab=adopt-clickops-ec2..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "[DRY RUN] Would terminate any orphan instance / delete any orphan SG tagged Lab=adopt-clickops-ec2."
  else
    orphan_instances="$(aws ec2 describe-instances \
      --region "${AWS_REGION}" \
      --filters \
        "Name=tag:Lab,Values=adopt-clickops-ec2" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
    if [[ -n "${orphan_instances}" ]]; then
      log_warn "Found unmanaged instance(s): ${orphan_instances} — terminating (adopt/ was skipped)."
      # shellcheck disable=SC2086
      aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids ${orphan_instances} >/dev/null || true
      # shellcheck disable=SC2086
      aws ec2 wait instance-terminated --region "${AWS_REGION}" --instance-ids ${orphan_instances} || true
      log_success "Orphan instance(s) terminated."
    else
      log_info "No unmanaged instances to sweep (adopt/ likely handled them)."
    fi
    # SGs can only be deleted once their ENIs (the instance) are gone.
    orphan_sgs="$(aws ec2 describe-security-groups \
      --region "${AWS_REGION}" \
      --filters "Name=tag:Lab,Values=adopt-clickops-ec2" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)"
    for sg in ${orphan_sgs}; do
      if aws ec2 delete-security-group --region "${AWS_REGION}" --group-id "${sg}" 2>/dev/null; then
        log_success "Deleted unmanaged SG ${sg}."
      else
        log_warn "Could not delete SG ${sg} yet (may still be in use / already gone) — stage destroy will retry."
      fi
    done
  fi
  echo ""
fi

# ─── 2. Destroy stage/ (network + IAM) ────────────────────────────────────────
if [[ "$STAGE_HAS_STATE" == "true" ]]; then
  log_info "Destroying stage/ (VPC, subnet, IGW, route table, agent IAM)..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "[DRY RUN] Would run: terraform -chdir=${STAGE_DIR} destroy -auto-approve"
  else
    if terraform -chdir="${STAGE_DIR}" destroy -auto-approve; then
      log_success "stage/ destroyed."
    else
      log_error "stage/ destroy failed. Check the output above."
      log_warn "Common cause: the legacy instance/SG are still sitting there unmanaged"
      log_warn "because adopt/ was never run — they will NOT be caught by stage's destroy"
      log_warn "(they're not in its state). Delete them manually if adopt/ was skipped:"
      log_warn "  aws ec2 terminate-instances --region ${AWS_REGION} --instance-ids <id>"
      log_warn "  aws ec2 delete-security-group --region ${AWS_REGION} --group-id <id>"
    fi
  fi
else
  log_warn "stage/ has no state — skipping (already destroyed, or setup never ran)."
fi

# ─── Verify cleanup ───────────────────────────────────────────────────────────
echo ""
log_info "Verifying no lab instances remain (best-effort, tag-based)..."
if [[ "$DRY_RUN" != "true" ]]; then
  remaining="$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters \
      "Name=tag:Lab,Values=adopt-clickops-ec2" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || true)"

  if [[ -z "${remaining}" ]]; then
    log_success "No EC2 instances tagged Lab=adopt-clickops-ec2 remain."
  else
    log_warn "Instances still present: ${remaining}"
    log_warn "Check the AWS Console to confirm — they may just be terminating."
  fi
fi

# ─── Completion summary ───────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Cleanup complete!                           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
log_success "All lab resources have been destroyed (or were already gone)."
echo ""
echo -e "${YELLOW}Estimated savings: ~\$0.03/hour by removing the t3.small instance (VPC/IAM cost \$0).${NC}"
echo ""
echo "Double-check these services in the AWS Console to confirm nothing was missed:"
echo "  - EC2 > Instances             https://console.aws.amazon.com/ec2/v2/home?region=${AWS_REGION}#Instances"
echo "  - EC2 > Security Groups       https://console.aws.amazon.com/ec2/v2/home?region=${AWS_REGION}#SecurityGroups"
echo "  - VPC > Your VPCs             https://console.aws.amazon.com/vpcconsole/home?region=${AWS_REGION}#vpcs"
echo "  - IAM > Policies / Users      https://console.aws.amazon.com/iamv2/home#/policies"
echo "  - Billing > Cost Explorer     https://console.aws.amazon.com/cost-management/home"
echo ""
