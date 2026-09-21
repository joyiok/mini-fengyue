#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

bash ./scripts/preflight.sh
docker compose ps

RUNNING_SERVICES="$(docker compose ps --status running --services 2>/dev/null || true)"

if ! grep -qx 'sillytavern' <<<"$RUNNING_SERVICES"; then
  die "The sillytavern container is not running. Inspect: docker compose logs --tail=100 sillytavern"
fi

if docker compose exec -T sillytavern node src/healthcheck.js >/dev/null 2>&1; then
  log "SillyTavern health check: OK"
else
  die "SillyTavern health check failed. Inspect: docker compose logs --tail=100 sillytavern"
fi

if ! grep -qx 'caddy' <<<"$RUNNING_SERVICES"; then
  die "The caddy container is not running. Inspect: docker compose logs --tail=100 caddy"
fi
log "Caddy container: running"

if [[ "${SKIP_PROXY_CHECK:-}" == "YES" ]]; then
  warn "Skipping the reverse-proxy reachability check (SKIP_PROXY_CHECK=YES)."
  exit 0
fi

if ! have curl; then
  warn "curl is not installed; skipping the reverse-proxy reachability check."
  exit 0
fi

APP_DOMAIN_VALUE="$(setting_or APP_DOMAIN ':80')"
# APP_DOMAIN may list several hosts; the first one is the canonical address.
PRIMARY_DOMAIN_VALUE="$(primary_domain "$APP_DOMAIN_VALUE" || true)"

if [[ "$PRIMARY_DOMAIN_VALUE" =~ ^:([0-9]+)$ ]]; then
  HOST="127.0.0.1"
  PORT="${BASH_REMATCH[1]}"
  URL="http://127.0.0.1:${PORT}/"
  CURL_ARGS=(--max-time 15)
else
  TARGET="${PRIMARY_DOMAIN_VALUE#*://}"
  HOST="$TARGET"
  PORT="443"
  if [[ "$TARGET" =~ ^([^:]+):([0-9]+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    PORT="${BASH_REMATCH[2]}"
  fi
  URL="https://${HOST}:${PORT}/"
  # Talk to the local Caddy rather than to public DNS. This also proves a
  # certificate for the host was issued and is being served.
  CURL_ARGS=(--max-time 15 --resolve "${HOST}:${PORT}:127.0.0.1")
fi

HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "${CURL_ARGS[@]}" "$URL" 2>/dev/null || true)"
HTTP_CODE="${HTTP_CODE:-000}"

# 2xx/3xx means the proxy chain works. 401/403 is also a pass: this check is
# about TLS and the reverse proxy, not about application authentication.
case "$HTTP_CODE" in
  2*|3*|401|403)
    log "Reverse proxy check: OK ($URL -> HTTP $HTTP_CODE)"
    ;;
  000|"")
    die "Could not reach $URL through Caddy (TLS or connection failure). Inspect: docker compose logs --tail=50 caddy"
    ;;
  *)
    die "Unexpected HTTP $HTTP_CODE from $URL. Inspect: docker compose logs --tail=50 caddy"
    ;;
esac
