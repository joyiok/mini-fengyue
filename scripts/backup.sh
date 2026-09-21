#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p backups
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="backups/story-tavern-${STAMP}.tar.gz"

# Secrets in .env are intentionally excluded. Back up that file separately in
# a password manager or another encrypted location if you need it.
tar --exclude='./backups' --exclude='./.env' -czf "$ARCHIVE" \
  ./config ./data ./plugins ./extensions ./caddy Caddyfile docker-compose.yml
chmod 600 "$ARCHIVE"
echo "$ARCHIVE"

