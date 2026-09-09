#!/usr/bin/env bash
# 02-agent-discover.sh — OPTIONAL, illustrative only
#
# Shows what a read-only discovery agent sees when it looks at the legacy
# EC2 instance + SG — plain `aws ec2 describe-*` calls, nothing an agent
# does that you couldn't run yourself. The lab's actual demo path is
# DETERMINISTIC: it uses the pre-baked ../adopt/agent-draft.tf.example
# rather than a live agent run, so `terraform plan`'s output is reproducible
# on camera. Run this only if you want to show the discovery step itself.
#
# Usage:
#   ./02-agent-discover.sh <instance-id> <sg-id>
#   ./02-agent-discover.sh --help
#
# Requires read-only AWS credentials (the agent's, or your own — this
# script only calls Describe* actions).

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ "${1:-}" == "--help" || $# -lt 2 ]]; then
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

INSTANCE_ID="$1"
SG_ID="$2"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"

echo ""
log_info "Discovering instance ${INSTANCE_ID} (region ${AWS_REGION})..."
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,Ami:ImageId,Subnet:SubnetId,State:State.Name}' \
  --output table

echo ""
log_info "Discovering security group ${SG_ID}..."
aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --group-ids "${SG_ID}" \
  --query 'SecurityGroups[].{Name:GroupName,Vpc:VpcId,Ingress:IpPermissions}' \
  --output table

echo ""
log_success "This is the raw material an agent would use to draft .tf — compare"
echo "the real Ami above against what ../adopt/agent-draft.tf.example writes."
