#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

# Guard against running the purge from the wrong directory.
if [[ ! -f docker-compose.yml || ! -f Caddyfile ]]; then
  die "Run this script from the Mini Story repository (docker-compose.yml and Caddyfile not found)."
fi

if have docker && docker compose version >/dev/null 2>&1; then
  log "Stopping the stack..."
  docker compose down
else
  warn "Docker Compose is not available; skipping container shutdown."
fi

if [[ "${CONFIRM_PURGE:-}" != "YES" ]]; then
  log "Containers stopped. Private data in ./data, ./config and ./backups was kept."
  log "To delete it as well: CONFIRM_PURGE=YES ./scripts/uninstall.sh"
  exit 0
fi

log "Deleting runtime data (./data, ./caddy, ./backups, config/config.yaml, .env)..."
PURGE_FAILED=0

# Older versions ran the Caddy container as root and left files the normal user
# cannot remove. Clear those through a throwaway container before the plain rm.
if [[ -d caddy ]] && caddy_storage_is_unusable; then
  log "Clearing root-owned leftovers in ./caddy via a helper container..."
  if ! docker run --rm -v "$ROOT_DIR/caddy:/target" "${CADDY_IMAGE:-caddy:2-alpine}" \
    find /target -mindepth 1 -delete >/dev/null 2>&1; then
    warn "The helper container could not clear ./caddy."
    PURGE_FAILED=1
  fi
fi

for path in ./data ./caddy ./backups; do
  rm -rf -- "$path" 2>/dev/null || true
  if [[ -e "$path" ]]; then
    warn "Could not remove $path"
    PURGE_FAILED=1
  fi
done

rm -f -- config/config.yaml .env 2>/dev/null || true

if (( PURGE_FAILED )); then
  warn "Purge incomplete. Remove the leftovers manually, for example:"
  warn "  sudo rm -rf data caddy backups config/config.yaml .env"
  exit 1
fi

log "Purge complete. Files tracked by Git were not touched."
