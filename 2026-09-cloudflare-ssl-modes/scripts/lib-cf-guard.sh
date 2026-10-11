#!/usr/bin/env bash
# lib-cf-guard.sh - shared helpers for every script in this lab that talks to Cloudflare.
# SOURCE it, do not run it:   source "$(dirname "$0")/lib-cf-guard.sh"
#
# Why this exists: the Cloudflare API token the CuliOps lab uses can reach PRODUCTION zones, and
# this lab changes a ZONE-WIDE setting (SSL/TLS mode). So before ANY write, cf_guard_zone looks
# the zone up by id and aborts unless its name is the lab zone (default: culilab.dev) - and
# refuses outright if it is one of the protected production zones.
#
# Needs in the environment: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE_ID
# Optional:                 LAB_ZONE_NAME (default culilab.dev)

CF_API="https://api.cloudflare.com/client/v4"
LAB_ZONE_NAME="${LAB_ZONE_NAME:-culilab.dev}"
PROTECTED_ZONES=(culiops.dev culipulse.dev 1cost.dev)

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi
ok()   { echo "${GREEN}✔${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }
bad()  { echo "${RED}✖${RESET} $*"; }
die()  { echo "${RED}${BOLD}ABORT:${RESET} $*" >&2; exit 2; }

# cf_curl <curl args...> - curl with the bearer token passed via a config on stdin, so the token
# never shows up in `ps` output.
cf_curl() {
  curl -sS --max-time 30 --config <(printf 'header = "Authorization: Bearer %s"\n' "${CLOUDFLARE_API_TOKEN}") \
    -H "Content-Type: application/json" "$@"
}

# cf_require_env - fail early with a useful message.
cf_require_env() {
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "CLOUDFLARE_API_TOKEN is not set (run: source .env)"
  [ -n "${CLOUDFLARE_ZONE_ID:-}" ]  || die "CLOUDFLARE_ZONE_ID is not set (run: source .env)"
}

# cf_guard_zone - abort unless the zone behind CLOUDFLARE_ZONE_ID is the lab zone.
# On success sets ZONE_NAME. Call it before EVERY write.
cf_guard_zone() {
  cf_require_env
  local resp name id
  resp="$(cf_curl "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}")" || die "could not read zone ${CLOUDFLARE_ZONE_ID} from the Cloudflare API"
  # Fail CLOSED: if the response shape is not exactly what we expect, name stays empty and we abort.
  id="$(printf '%s' "$resp"   | sed -n 's/^{"result":{"id":"\([0-9a-f]*\)",.*/\1/p')"
  name="$(printf '%s' "$resp" | sed -n 's/^{"result":{"id":"[0-9a-f]*","name":"\([^"]*\)".*/\1/p')"
  if [ -z "$name" ] || [ "$id" != "${CLOUDFLARE_ZONE_ID}" ]; then
    die "could not confirm the zone name for id ${CLOUDFLARE_ZONE_ID} (token lacks Zone:Read, or wrong id?) - refusing to write"
  fi
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

  local p
  for p in "${PROTECTED_ZONES[@]}"; do
    [ "$name" != "$p" ] || die "zone '${name}' is a PRODUCTION zone. This lab changes zone-wide SSL settings and must only run on a throwaway zone."
  done
  [ "$name" = "$(printf '%s' "${LAB_ZONE_NAME}" | tr '[:upper:]' '[:lower:]')" ] \
    || die "zone id ${CLOUDFLARE_ZONE_ID} is '${name}', but LAB_ZONE_NAME is '${LAB_ZONE_NAME}'. Wrong CLOUDFLARE_ZONE_ID?"
  ZONE_NAME="$name"
  ok "zone guard passed: ${ZONE_NAME} (${CLOUDFLARE_ZONE_ID})"
}

# cf_get_setting <name> - print the zone setting's value, or nothing if it cannot be read.
cf_get_setting() {
  local resp
  resp="$(cf_curl "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/settings/$1" 2>/dev/null)" || return 0
  printf '%s' "$resp" | grep -q '"success":true' || return 0
  printf '%s' "$resp" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p' | head -1
}

# cf_set_setting <name> <value> - PATCH a zone setting. Returns 0 only if the API said success.
# Call cf_guard_zone first.
cf_set_setting() {
  local resp
  resp="$(cf_curl -X PATCH "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/settings/$1" --data "{\"value\":\"$2\"}" 2>/dev/null)" || return 1
  printf '%s' "$resp" | grep -q '"success":true'
}
