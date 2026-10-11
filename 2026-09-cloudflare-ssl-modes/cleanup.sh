#!/usr/bin/env bash
# cleanup.sh - CuliOps Lab: Cloudflare SSL Modes
#
# Teardown has TWO halves, because the lab does too:
#   1. The ZONE-WIDE SSL/TLS settings you changed BY HAND (Flexible -> Full -> Full strict).
#      Terraform never owned them, so `terraform destroy` cannot undo them - this script restores
#      the values prepare-zone.sh saved in .zone-ssl-before.env.
#   2. The stage Terraform built (EC2, EIP, VPC, SG, IAM, and the proxied DNS record) - destroyed
#      with `terraform destroy`.
# Then it VERIFIES, and tells you what it could NOT do for you: the Cloudflare Origin CA
# certificate. The token has no SSL-and-Certificates permission, so revoking it is a manual step.
#
# Honest by design: it never prints a green "complete" while a step failed or a manual item remains.
#
# Usage:  source .env && ./cleanup.sh [--yes]
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${HERE}/.zone-ssl-before.env"
# shellcheck source=scripts/lib-cf-guard.sh
source "${HERE}/scripts/lib-cf-guard.sh"

YES=0
usage() {
  cat <<USAGE
Usage: $0 [--yes] [--help]

  --yes, -y   skip the confirmation prompt
  --help, -h  show this help

Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID (source .env), plus AWS credentials.
Refuses to touch any zone that is not LAB_ZONE_NAME (default culilab.dev), and always refuses
culiops.dev / culipulse.dev / 1cost.dev.
USAGE
}
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

trap 'bad "cleanup.sh stopped at line $LINENO. Billable AWS resources may still exist - re-run ./cleanup.sh (safe to repeat) or: cd terraform && terraform destroy"' ERR

ORIGIN_HOSTNAME="${ORIGIN_HOSTNAME:-app.culilab.dev}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
export TF_VAR_cloudflare_zone_id="${TF_VAR_cloudflare_zone_id:-${CLOUDFLARE_ZONE_ID:-}}"
export TF_VAR_lab_zone_name="${TF_VAR_lab_zone_name:-${LAB_ZONE_NAME}}"
export TF_VAR_origin_hostname="${TF_VAR_origin_hostname:-${ORIGIN_HOSTNAME}}"

FAILED=()   # things that went wrong and may still cost money / leave the zone changed
MANUAL=()   # things this script cannot do, or could not do - each a concrete step for you

# state_get <KEY> - read one KEY=value line from the saved state file
state_get() { sed -n "s/^$1=//p" "${STATE_FILE}" 2>/dev/null | head -1; }

dash_mode_name() { [ "$1" = "auto" ] && echo "Automatic SSL/TLS" || echo "Custom SSL/TLS"; }

echo "${BOLD}Cleanup - Cloudflare SSL Modes lab${RESET}"
echo "======================================"
cf_guard_zone   # abort BEFORE the prompt if this is not the lab zone

echo ""
echo "This will:"
echo "  1. Restore the zone's SSL/TLS settings on ${ZONE_NAME}  (from .zone-ssl-before.env)"
echo "       ssl                -> $(state_get SSL || true)"
echo "       ssl_automatic_mode -> $(state_get SSL_AUTOMATIC_MODE || true)"
echo "  2. terraform destroy: EC2 origin, Elastic IP, VPC/subnet/IGW/route table, security group,"
echo "     IAM role + instance profile, and the proxied DNS record ${ORIGIN_HOSTNAME}"
echo "  3. Verify: DNS record gone, no lab instance/EIP left, SSL mode restored"
echo ""
echo "It will NOT revoke the Cloudflare Origin CA certificate - that is a manual step (listed at the end)."
echo ""
if [ "${YES}" -ne 1 ]; then
  read -r -p "Continue? (y/N) " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

# --- Half 1: zone SSL settings (changed by hand -> not owned by Terraform) ----------------------
echo ""
echo "${BOLD}-> Cloudflare: restoring the zone's SSL settings${RESET}"
SSL_RESTORED=0
AUTO_RESTORED=0
if [ ! -f "${STATE_FILE}" ]; then
  bad "no .zone-ssl-before.env - I do not know what the zone looked like before the lab."
  MANUAL+=("Restore the SSL/TLS encryption mode on ${ZONE_NAME} to its pre-lab value (Dashboard -> SSL/TLS -> Overview). The lab's starting point was Flexible; your original is unknown to this script.")
else
  want_ssl="$(state_get SSL)"
  want_auto="$(state_get SSL_AUTOMATIC_MODE)"
  [ "$(state_get ZONE_ID)" = "${CLOUDFLARE_ZONE_ID}" ] || die ".zone-ssl-before.env belongs to a different zone ($(state_get ZONE_ID)). Refusing to restore it onto ${CLOUDFLARE_ZONE_ID}."

  # ssl first (while the zone is still on Custom), then ssl_automatic_mode.
  cur="$(cf_get_setting ssl)"
  if [ "${cur}" = "${want_ssl}" ]; then
    ok "ssl already '${want_ssl}'"; SSL_RESTORED=1
  elif cf_set_setting ssl "${want_ssl}" && [ "$(cf_get_setting ssl)" = "${want_ssl}" ]; then
    ok "ssl restored: '${cur}' -> '${want_ssl}'"; SSL_RESTORED=1
  else
    bad "could not restore ssl to '${want_ssl}' (zone is '${cur:-unknown}')"
    FAILED+=("SSL mode not restored (zone is '${cur:-unknown}', wanted '${want_ssl}')")
    MANUAL+=("Set SSL/TLS encryption mode on ${ZONE_NAME} to '${want_ssl}': Dashboard -> SSL/TLS -> Overview.")
  fi

  # Best-effort: if the PATCH is refused we print the dashboard step and do NOT claim success.
  cur_auto="$(cf_get_setting ssl_automatic_mode)"
  if [ "${want_auto}" = "unknown" ] || [ -z "${want_auto}" ]; then
    warn "ssl_automatic_mode was not recorded before the lab"
    MANUAL+=("Check the Automatic vs Custom SSL/TLS choice on ${ZONE_NAME} (Dashboard -> SSL/TLS -> Overview) - its original value was not recorded.")
  elif [ "${cur_auto}" = "${want_auto}" ]; then
    ok "ssl_automatic_mode already '${want_auto}'"; AUTO_RESTORED=1
  elif cf_set_setting ssl_automatic_mode "${want_auto}" && [ "$(cf_get_setting ssl_automatic_mode)" = "${want_auto}" ]; then
    ok "ssl_automatic_mode restored: '${cur_auto}' -> '${want_auto}'"; AUTO_RESTORED=1
  else
    warn "could not restore ssl_automatic_mode via the API (zone is '${cur_auto:-unknown}', wanted '${want_auto}') - NOT restored"
    MANUAL+=("Select '$(dash_mode_name "${want_auto}")' on ${ZONE_NAME}: Dashboard -> SSL/TLS -> Overview -> $(dash_mode_name "${want_auto}").")
  fi
fi

# --- Half 2: the stage (owned by Terraform, incl. the proxied DNS record) -----------------------
echo ""
echo "${BOLD}-> AWS + Cloudflare DNS: terraform destroy${RESET}"
if ! command -v terraform >/dev/null 2>&1; then
  bad "terraform not found"
  FAILED+=("terraform destroy not run (terraform missing)")
elif [ ! -d "${HERE}/terraform" ]; then
  bad "terraform/ directory not found next to this script"
  FAILED+=("terraform destroy not run (no terraform/ directory)")
else
  if ( cd "${HERE}/terraform" \
       && { [ -d .terraform ] || terraform init -input=false >/dev/null; } \
       && terraform destroy -auto-approve -input=false ); then
    ok "terraform destroy finished"
  else
    bad "terraform destroy FAILED - billable resources may remain"
    FAILED+=("terraform destroy failed: cd terraform && terraform destroy   (then re-run ./cleanup.sh)")
  fi
fi

# --- Verify -------------------------------------------------------------------------------------
echo ""
echo "${BOLD}-> Verifying${RESET}"

recs="$(cf_curl "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${ORIGIN_HOSTNAME}" 2>/dev/null || true)"
if printf '%s' "${recs}" | grep -q '"success":true'; then
  if printf '%s' "${recs}" | grep -q '"result":\[\]'; then
    ok "DNS record ${ORIGIN_HOSTNAME}: gone"
  else
    bad "DNS record ${ORIGIN_HOSTNAME} still exists"
    FAILED+=("DNS record ${ORIGIN_HOSTNAME} still exists - delete it: Dashboard -> DNS -> Records")
  fi
else
  warn "could not check the DNS record (API call failed) - verify it in the dashboard"
  MANUAL+=("Confirm ${ORIGIN_HOSTNAME} no longer has a DNS record: Dashboard -> DNS -> Records.")
fi

if command -v aws >/dev/null 2>&1; then
  leftovers="$(aws ec2 describe-instances --region "${AWS_REGION}" \
      --filters "Name=tag:Lab,Values=cloudflare-ssl-modes" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)" || leftovers="__error__"
  if [ "${leftovers}" = "__error__" ]; then
    warn "could not query EC2 (credentials?) - check EC2 > Instances yourself"
    MANUAL+=("Confirm no instance tagged Lab=cloudflare-ssl-modes is left in ${AWS_REGION} (EC2 > Instances).")
  elif [ -n "${leftovers}" ]; then
    bad "instance(s) still alive: ${leftovers}"
    FAILED+=("EC2 instance(s) still alive: ${leftovers}")
  else
    ok "no lab EC2 instance left"
  fi
  eips="$(aws ec2 describe-addresses --region "${AWS_REGION}" \
      --filters "Name=tag:Lab,Values=cloudflare-ssl-modes" \
      --query 'Addresses[].AllocationId' --output text 2>/dev/null)" || eips="__error__"
  if [ "${eips}" = "__error__" ]; then
    warn "could not query Elastic IPs - check EC2 > Elastic IPs yourself"
  elif [ -n "${eips}" ]; then
    bad "Elastic IP(s) still allocated (billing): ${eips}"
    FAILED+=("Elastic IP(s) still allocated: ${eips}")
  else
    ok "no lab Elastic IP left"
  fi
else
  warn "aws CLI not found - cannot verify AWS side"
  MANUAL+=("Confirm no instance / Elastic IP tagged Lab=cloudflare-ssl-modes is left in ${AWS_REGION}.")
fi

if [ "${SSL_RESTORED}" -eq 1 ] && [ "$(cf_get_setting ssl)" = "$(state_get SSL)" ]; then
  ok "zone SSL mode: $(cf_get_setting ssl) (as before the lab)"
fi
# The saved state has done its job only if BOTH settings are verified restored; otherwise keep it.
if [ "${SSL_RESTORED}" -eq 1 ] && [ "${AUTO_RESTORED}" -eq 1 ]; then
  rm -f "${STATE_FILE}"
fi

# The one thing this script can never do for you.
MANUAL+=("REVOKE the Cloudflare Origin CA certificate for ${ORIGIN_HOSTNAME}: Dashboard -> ${ZONE_NAME} -> SSL/TLS -> Origin Server -> Origin Certificates -> select it -> Revoke. (The API token has no SSL-and-Certificates permission. Revoking cannot be undone.)")
MANUAL+=("Delete any copy of the Origin CA certificate/private key you saved locally (the copy on the instance disappears with the instance).")

# --- Verdict ------------------------------------------------------------------------------------
echo ""
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "${RED}${BOLD}CLEANUP INCOMPLETE - something failed and may still cost money:${RESET}"
  for f in "${FAILED[@]}"; do echo "  ${RED}-${RESET} ${f}"; done
else
  echo "${GREEN}${BOLD}Automated cleanup finished and verified.${RESET}  Est. saved: ~\$0.02/hour (~\$0.46/day): t3.micro + public IPv4 + 8 GB gp3."
fi
echo ""
echo "${YELLOW}${BOLD}Still on YOU (not done by this script):${RESET}"
for m in "${MANUAL[@]}"; do echo "  [ ] ${m}"; done
echo ""
[ "${#FAILED[@]}" -eq 0 ] || exit 1
