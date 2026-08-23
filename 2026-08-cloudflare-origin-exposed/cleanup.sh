#!/usr/bin/env bash
# cleanup.sh — CuliOps Lab: Cloudflare Origin Lockdown
#
# Teardown has TWO halves, because the lab does too:
#   1. The Cloudflare zone artifacts YOU created by hand in the demo (a proxied A record, the
#      SSL mode, the Authenticated Origin Pulls toggle). Terraform never owned these, so
#      `terraform destroy` can't remove them — this script reverses each one (every "off" here
#      mirrors an "on" step from the demo).
#   2. The AWS stage Terraform built (VPC, EC2, EIP, security group) — `terraform destroy`.
#
# ⚠️  Run this when you're done, or you'll leave a billable EIP + EC2 running and your throwaway
#     zone with AOP still on.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_API="https://api.cloudflare.com/client/v4"

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
ok()   { echo "${GREEN}✔${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }

echo "${BOLD}🧹 CuliOps Lab Cleanup — Cloudflare Origin Lockdown${RESET}"
echo "======================================================"
echo ""
echo "This will:"
echo "  1. Turn OFF Authenticated Origin Pulls (tls_client_auth) on the zone"
echo "  2. Delete the proxied A record for \${ORIGIN_HOSTNAME}"
echo "  3. Reset the zone SSL mode to 'flexible' (the demo set it to 'full')"
echo "  4. terraform destroy — remove the EC2 origin, EIP, VPC, and security group"
echo ""
read -r -p "Continue? (y/N) " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# ─── Half 1: Cloudflare zone artifacts (created by hand → not owned by Terraform) ──────────────
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${CLOUDFLARE_ZONE_ID:-}" && -n "${ORIGIN_HOSTNAME:-}" ]]; then
  auth=(-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json")

  echo ""
  echo "→ Cloudflare: turning Authenticated Origin Pulls OFF"
  curl -fsS -X PATCH "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/settings/tls_client_auth" \
    "${auth[@]}" --data '{"value":"off"}' >/dev/null && ok "AOP off" || warn "AOP toggle failed (may already be off)"

  echo "→ Cloudflare: deleting the proxied A record for ${ORIGIN_HOSTNAME}"
  # CF DNS record ids are 32 hex chars; take the first match from the name+type lookup.
  rec_id="$(curl -fsS "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=A&name=${ORIGIN_HOSTNAME}" \
    "${auth[@]}" | grep -oE '"id":"[0-9a-f]{32}"' | head -1 | cut -d'"' -f4 || true)"
  if [[ -n "${rec_id}" ]]; then
    curl -fsS -X DELETE "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${rec_id}" \
      "${auth[@]}" >/dev/null && ok "A record ${rec_id} deleted" || warn "record delete failed"
  else
    warn "no A record found for ${ORIGIN_HOSTNAME} (already gone?)"
  fi

  echo "→ Cloudflare: resetting SSL mode to 'flexible'"
  curl -fsS -X PATCH "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/settings/ssl" \
    "${auth[@]}" --data '{"value":"flexible"}' >/dev/null && ok "SSL mode reset" || warn "SSL reset failed"
else
  warn "CLOUDFLARE_* env not set — skipping Cloudflare cleanup."
  warn "Set CLOUDFLARE_API_TOKEN / CLOUDFLARE_ZONE_ID / ORIGIN_HOSTNAME (source .env) and re-run,"
  warn "or turn AOP off + delete the A record + reset SSL mode in the dashboard by hand."
fi

# ─── Half 2: the AWS stage (owned by Terraform) ───────────────────────────────────────────────
echo ""
echo "→ AWS: terraform destroy (EC2, EIP, VPC, security group)"
if [[ -d "${HERE}/terraform" ]]; then
  ( cd "${HERE}/terraform" && terraform destroy -auto-approve )
  ok "AWS stage destroyed"
else
  warn "terraform/ dir not found next to this script — run 'terraform destroy' yourself."
fi

echo ""
echo "${GREEN}${BOLD}✅ Cleanup complete.${RESET}"
echo "💰 Estimated savings: ~\$0.25/day (t3.micro + Elastic IP) now that the origin is gone."
echo ""
echo "Double-check in the AWS Console:  EC2 > Instances · EC2 > Elastic IPs · VPC > Your VPCs"
echo "And in Cloudflare:  DNS (record gone) · SSL/TLS (mode = Flexible, AOP off)"
