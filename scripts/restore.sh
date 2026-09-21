#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  echo "Usage: $0 backups/story-tavern-YYYYmmdd-HHMMSS.tar.gz" >&2
  exit 2
fi

if [[ "${CONFIRM_RESTORE:-}" != "YES" ]]; then
  echo "Restore overwrites config and private data. Set CONFIRM_RESTORE=YES to continue." >&2
  exit 1
fi

docker compose down
tar -xzf "$ARCHIVE" -C "$ROOT_DIR"
docker compose up -d
docker compose ps

