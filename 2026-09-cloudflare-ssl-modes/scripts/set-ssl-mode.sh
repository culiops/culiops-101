#!/usr/bin/env bash
# set-ssl-mode.sh - OPTIONAL: change the zone's SSL mode from the terminal instead of the dashboard.
#
# The lab's lesson is the mode change itself, so the README does it by hand in the dashboard.
# This script is the reproducible fallback (same effect, same zone-wide setting). It is guarded:
# it refuses to run unless the zone is the lab zone (see lib-cf-guard.sh).
#
# Usage:  source .env && ./scripts/set-ssl-mode.sh <flexible|full|strict>
#   flexible = Flexible · full = Full · strict = Full (strict)
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-cf-guard.sh
source "${HERE}/lib-cf-guard.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

MODE="${1:-}"
case "${MODE}" in
  flexible|full|strict) ;;
  *) usage; exit 1 ;;
esac

trap 'bad "set-ssl-mode failed at line $LINENO. Nothing billable is created by this script."' ERR

cf_guard_zone
before="$(cf_get_setting ssl)"
cf_set_setting ssl "${MODE}" || die "the API refused ssl=${MODE} (token needs Zone Settings:Edit; zone must be on Custom SSL/TLS)"
after="$(cf_get_setting ssl)"
[ "${after}" = "${MODE}" ] || die "asked for '${MODE}' but the zone reports '${after}'"
ok "ssl: '${before}' -> '${after}'  (give Cloudflare ~15-30s to propagate before you test)"
