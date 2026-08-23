#!/usr/bin/env bash
# check-origin.sh — the 30-second "is my origin exposed?" check from the video.
#
# It pretends to be someone who already knows your origin IP and calls it directly,
# still claiming your domain (SNI + Host). If the origin answers, it is accepting
# requests that never passed through Cloudflare — i.e. exposed.
#
# Usage:
#   ./check-origin.sh <domain> <origin_ip>
#   ./check-origin.sh cf-origin.culilab.dev 203.0.113.10
set -euo pipefail

usage() { echo "Usage: $0 <domain> <origin_ip>"; exit 1; }
[ $# -eq 2 ] || usage
DOMAIN="$1"
ORIGIN_IP="$2"

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

echo "${BOLD}1) Direct hit on the origin IP over HTTPS (bypasses Cloudflare):${RESET}"
# -k (insecure): an origin behind Cloudflare usually serves a cert that is NOT publicly
# trusted (self-signed, or a Cloudflare Origin CA cert). We are testing *reachability*, not
# cert validity — exactly what an attacker probing for an exposed origin does. Without -k,
# a self-signed cert makes curl exit with an error (000) and hides that the origin is exposed.
CODE=$(curl -sSk --max-time 10 --resolve "$DOMAIN:443:$ORIGIN_IP" \
  "https://$DOMAIN/" -o /dev/null -w '%{http_code}' 2>/dev/null) || true
[ -z "$CODE" ] && CODE="000"

case "$CODE" in
  200) echo "   -> ${RED}${BOLD}$CODE  EXPOSED${RESET} — the origin answered a request that skipped Cloudflare." ;;
  000) echo "   -> ${GREEN}${BOLD}timeout/refused  LOCKED (Layer 1)${RESET} — a network firewall dropped the direct hit." ;;
  403) echo "   -> ${GREEN}${BOLD}$CODE  LOCKED (Layer 2)${RESET} — the origin rejected a request with no Cloudflare client cert (mTLS)." ;;
  *)   echo "   -> ${YELLOW}${BOLD}$CODE${RESET} — unexpected; inspect manually." ;;
esac

echo ""
echo "${BOLD}2) The legit path, through Cloudflare (should stay 200):${RESET}"
VIA=$(curl -sS --max-time 10 "https://$DOMAIN/" -o /dev/null -w '%{http_code}' 2>/dev/null) || true
[ -z "$VIA" ] && VIA="000"
echo "   -> $VIA"

echo ""
if [ "$CODE" = "200" ]; then
  echo "${RED}Verdict: origin is reachable directly. Every Cloudflare rule (WAF, rate-limit, DDoS) is optional for an attacker who knows this IP.${RESET}"
else
  echo "${GREEN}Verdict: the direct path is blocked; traffic is forced through Cloudflare.${RESET}"
fi
