#!/usr/bin/env bash
# prepare-zone.sh - Setup step: remember the zone's SSL settings, then put the zone in the lab's
# STARTING STATE (SSL mode = Flexible, "Custom SSL/TLS" selected).
#
#   1. SAVE   the zone's current `ssl` and `ssl_automatic_mode` to ../.zone-ssl-before.env
#             (cleanup.sh restores exactly these). Never overwritten once it exists - a second run
#             must not "remember" the already-modified state.
#   2. STAGE  set ssl_automatic_mode=custom and ssl=flexible - the deliberately wrong starting
#             point. This is plumbing, not the lesson: the lesson is every change AFTER this.
#
# SSL mode is a ZONE-WIDE setting, so a safety guard refuses to run unless the zone is the lab zone.
#
# Usage:  source .env && ./scripts/prepare-zone.sh
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${HERE}/.." && pwd)"
STATE_FILE="${LAB_ROOT}/.zone-ssl-before.env"
# shellcheck source=scripts/lib-cf-guard.sh
source "${HERE}/lib-cf-guard.sh"

usage() {
  cat <<USAGE
Usage: $0 [--help]

Saves the zone's current SSL settings to .zone-ssl-before.env (once), then sets the zone to the
lab's starting state: Custom SSL/TLS + Flexible.

Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID (source .env). Refuses to run unless the zone
is LAB_ZONE_NAME (default: culilab.dev) and is not a protected production zone.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

trap 'bad "prepare-zone failed at line $LINENO. Nothing billable was created. Re-running is safe."' ERR

echo "${BOLD}Prepare the lab zone${RESET}"
cf_guard_zone

# --- 1) SAVE the original state (once) ---------------------------------------------------------
if [ -f "${STATE_FILE}" ]; then
  warn "${STATE_FILE##*/} already exists - keeping it (it holds the ORIGINAL state):"
  sed 's/^/    /' "${STATE_FILE}"
else
  before_ssl="$(cf_get_setting ssl)"
  before_auto="$(cf_get_setting ssl_automatic_mode)"
  [ -n "${before_ssl}" ] || die "could not read the zone's current 'ssl' setting - refusing to change anything I cannot restore"
  [ -n "${before_auto}" ] || { warn "could not read ssl_automatic_mode; cleanup.sh will print the manual dashboard step for it"; before_auto="unknown"; }
  {
    echo "ZONE_ID=${CLOUDFLARE_ZONE_ID}"
    echo "ZONE_NAME=${ZONE_NAME}"
    echo "SSL=${before_ssl}"
    echo "SSL_AUTOMATIC_MODE=${before_auto}"
    echo "SAVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${STATE_FILE}"
  ok "saved original state to ${STATE_FILE##*/}:  ssl=${before_ssl}  ssl_automatic_mode=${before_auto}"
fi

# --- 2) STAGE the wrong starting state ---------------------------------------------------------
cur_auto="$(cf_get_setting ssl_automatic_mode)"
if [ "${cur_auto}" != "custom" ]; then
  if cf_set_setting ssl_automatic_mode custom; then
    ok "ssl_automatic_mode -> custom"
  else
    warn "could not set ssl_automatic_mode via API. Do it by hand: Dashboard -> SSL/TLS -> Overview -> Custom SSL/TLS"
  fi
else
  ok "ssl_automatic_mode already custom"
fi

cur_ssl="$(cf_get_setting ssl)"
if [ "${cur_ssl}" != "flexible" ]; then
  cf_set_setting ssl flexible || die "could not set ssl=flexible via API. Set it by hand: SSL/TLS -> Overview -> Flexible"
  ok "ssl -> flexible"
else
  ok "ssl already flexible"
fi

echo ""
echo "Zone is now:  ssl=$(cf_get_setting ssl)  ssl_automatic_mode=$(cf_get_setting ssl_automatic_mode)"
echo "Next: cd terraform && terraform init && terraform apply"
