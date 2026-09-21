#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

bash ./scripts/preflight.sh

# Record what is running now so a bad upgrade can be pinned back in .env.
log "Current images (record these before a version bump):"
docker compose images

./scripts/backup.sh >/dev/null

if [[ "${SKIP_PULL:-}" == "YES" ]]; then
  warn "Skipping the image pull (SKIP_PULL=YES); using whatever is already local."
else
  pull_images sillytavern caddy || die "Could not pull the required images; see the hints above."
fi
docker compose up -d --remove-orphans
docker compose ps

bash ./scripts/check.sh

if [[ "${PRUNE_IMAGES:-}" == "YES" ]]; then
  log "Pruning dangling images (PRUNE_IMAGES=YES)."
  docker image prune -f
else
  log "Previous images were kept so you can roll back instantly."
  log "Set PRUNE_IMAGES=YES to reclaim that disk space after a successful update."
fi
