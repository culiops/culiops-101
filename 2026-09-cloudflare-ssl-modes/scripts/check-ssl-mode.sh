#!/usr/bin/env bash
# check-ssl-mode.sh - "which SSL mode am I really in?" - read the status code, not the symptom.
#
# Read-only: it only sends GET/HEAD requests to your own hostname (no Cloudflare API calls).
#
#   1) the redirect-loop test from the video
#   2) the status code Cloudflare returns for the site
#   3) (optional) which certificate the ORIGIN itself presents, if you pass the origin IP
#
# Usage:
#   ./check-ssl-mode.sh [hostname] [origin_ip]
#   ./check-ssl-mode.sh app.culilab.dev 203.0.113.10
# hostname defaults to $ORIGIN_HOSTNAME, then app.culilab.dev.
set -Eeuo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HOST="${1:-${ORIGIN_HOSTNAME:-app.culilab.dev}}"
ORIGIN_IP="${2:-}"

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi
trap 'echo "${RED}check failed at line $LINENO${RESET} - nothing was changed by this script."' ERR

echo "${BOLD}1) Redirect-loop test (does the site bounce to ITSELF?):${RESET}"
# --stderr - is required: without it curl's error line prints BEFORE the piped 301s.
curl -sSIL --max-redirs 2 --stderr - "https://${HOST}/" | grep -iE '^(http|location|curl)' || true

echo ""
echo "${BOLD}2) Status code Cloudflare returns for https://${HOST}/ :${RESET}"
CODE="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "https://${HOST}/" 2>/dev/null)" || true
[ -n "${CODE}" ] || CODE="000"
case "${CODE}" in
  200) echo "   -> ${GREEN}${BOLD}200${RESET} - the site works. (Full accepts ANY origin cert; only Full (strict) proves it is a trusted one.)" ;;
  301|302|308) echo "   -> ${YELLOW}${BOLD}${CODE}${RESET} - redirect. If step 1 shows the SAME URL in 'location', that is the Flexible loop." ;;
  525) echo "   -> ${RED}${BOLD}525${RESET} - TLS HANDSHAKE with the origin failed (443 open but not speaking TLS - e.g. 'listen 443;' without ssl - or no common cipher). Fix the listener." ;;
  526) echo "   -> ${RED}${BOLD}526${RESET} - handshake worked but the origin CERTIFICATE is not valid/trusted (Full strict at work). Fix the certificate." ;;
  521|522|523) echo "   -> ${RED}${BOLD}${CODE}${RESET} - Cloudflare cannot reach the origin at all (down, still booting, or firewalled). Not an SSL-mode problem." ;;
  000) echo "   -> ${RED}${BOLD}no response${RESET} - DNS not resolving yet, or curl could not connect." ;;
  *)   echo "   -> ${YELLOW}${BOLD}${CODE}${RESET} - unexpected; inspect manually." ;;
esac

if [ -n "${ORIGIN_IP}" ]; then
  echo ""
  echo "${BOLD}3) Certificate the ORIGIN itself presents on :443 (bypassing Cloudflare):${RESET}"
  # -connect straight at the IP, SNI = the hostname. Informational only - we do not verify here.
  openssl s_client -connect "${ORIGIN_IP}:443" -servername "${HOST}" </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer -subject -enddate 2>/dev/null \
    | sed 's/^/   /' || echo "   (could not read a certificate from ${ORIGIN_IP}:443)"
  echo "   self-signed = issuer equals subject.  Cloudflare Origin CA = issuer mentions 'CloudFlare Origin SSL Certificate Authority'."
fi
