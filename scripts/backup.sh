#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p backups
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="backups/story-tavern-${STAMP}.tar.gz"
if [[ -z "${BACKUP_KEEP+x}" && -f .env ]]; then
  BACKUP_KEEP="$(awk -F= '
    $0 !~ /^[[:space:]]*#/ && $1 == "BACKUP_KEEP" {
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' .env)"
fi
BACKUP_KEEP="${BACKUP_KEEP:-14}"

if [[ ! "$BACKUP_KEEP" =~ ^[0-9]+$ ]]; then
  echo "BACKUP_KEEP must be a non-negative integer." >&2
  exit 1
fi

# Secrets in .env are intentionally excluded. Back up that file separately in
# a password manager or another encrypted location if you need it.
tar --exclude='./backups' --exclude='./.env' -czf "$ARCHIVE" \
  ./config ./data ./plugins ./extensions ./caddy Caddyfile docker-compose.yml
chmod 600 "$ARCHIVE"
sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"
chmod 600 "${ARCHIVE}.sha256"

if (( BACKUP_KEEP == 0 )); then
  echo "BACKUP_KEEP=0 means no local backup rotation; retaining the new archive."
else
  mapfile -t OLD_BACKUPS < <(
    find backups -maxdepth 1 -type f -name 'story-tavern-*.tar.gz' -printf '%T@ %p\n' |
      sort -nr |
      tail -n +$((BACKUP_KEEP + 1)) |
      cut -d' ' -f2-
  )
  for old_archive in "${OLD_BACKUPS[@]}"; do
    rm -f -- "$old_archive" "${old_archive}.sha256"
  done
fi

echo "$ARCHIVE"
