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

if ! tar -tzf "$ARCHIVE" >/dev/null; then
  echo "The backup archive is not a valid gzip-compressed tar archive." >&2
  exit 1
fi

if tar -tzf "$ARCHIVE" | grep -Eq '(^/|(^|/)\.\.(\/|$))'; then
  echo "Refusing an archive with absolute or parent-directory paths." >&2
  exit 1
fi

bash ./scripts/preflight.sh
docker compose down
tar -xzf "$ARCHIVE" -C "$ROOT_DIR" --no-same-owner --no-same-permissions
bash ./scripts/preflight.sh
docker compose up -d
docker compose ps
