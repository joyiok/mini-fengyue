#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

# Progress goes to stderr so stdout carries exactly one line: the archive path.
# scripts/restore.sh and any cron job can capture it directly.
note() { printf '%s\n' "$*" >&2; }

BACKUP_KEEP="$(setting_or BACKUP_KEEP 14)"
if [[ ! "$BACKUP_KEEP" =~ ^[0-9]+$ ]]; then
  die "BACKUP_KEEP must be a non-negative integer (got: $BACKUP_KEEP)."
fi

mkdir -p backups

# Only archive paths that exist. A fresh checkout has no data/, caddy/ or
# backups/ yet, and tar aborts the whole run on the first missing path.
BACKUP_PATHS=()
for path in ./config ./data ./plugins ./extensions ./caddy; do
  if [[ -e "$path" ]]; then
    BACKUP_PATHS+=("$path")
  fi
done

if (( ${#BACKUP_PATHS[@]} == 0 )); then
  die "Nothing to back up. Run ./scripts/install.sh first."
fi

if [[ ! -d ./data && ! -f ./config/config.yaml ]]; then
  warn "No SillyTavern data found yet; the archive will only hold the deployment profile."
fi

# Fail loudly rather than writing an archive that silently misses ./caddy.
if caddy_storage_is_unusable; then
  warn "./caddy is not usable by the container user (PUID:PGID = $(setting_or PUID 1000):$(setting_or PGID 1000))."
  warn "Re-run ./scripts/install.sh to fix ownership, or do it manually:"
  warn "  sudo chown -R $(setting_or PUID 1000):$(setting_or PGID 1000) caddy"
  die "Refusing to write a backup that would silently omit the Caddy certificates."
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="backups/story-tavern-${STAMP}.tar.gz"
PARTIAL="${ARCHIVE}.partial"

# Never leave a half-written archive behind: a partial file has no .sha256 and
# would look like a restorable backup.
cleanup_partial() { rm -f -- "$PARTIAL"; }
trap cleanup_partial EXIT

# .env is intentionally excluded (keep it in a password manager instead).
# config/config.yaml.example, Caddyfile and docker-compose.yml are code tracked
# in Git, so the archive contains private data only.
note "Archiving: ${BACKUP_PATHS[*]}"
set +e
tar --exclude='./backups' \
  --exclude='./.env' \
  --exclude='./config/config.yaml.example' \
  -czf "$PARTIAL" "${BACKUP_PATHS[@]}"
TAR_STATUS=$?
set -e

# GNU tar exits 1 for "file changed as we read it", which is expected while
# SillyTavern is running. Anything above that is a real failure.
if (( TAR_STATUS > 1 )); then
  die "tar failed with status $TAR_STATUS; no archive was written."
fi
if (( TAR_STATUS == 1 )); then
  warn "tar reported files that changed while being read; the archive is still usable."
fi

mv -f -- "$PARTIAL" "$ARCHIVE"
chmod 600 "$ARCHIVE"
sha256_line_of "$ARCHIVE" > "${ARCHIVE}.sha256"
chmod 600 "${ARCHIVE}.sha256"

if (( BACKUP_KEEP == 0 )); then
  note "BACKUP_KEEP=0: local rotation disabled, every archive is kept."
else
  mapfile -t OLD_BACKUPS < <(
    find backups -maxdepth 1 -type f -name 'story-tavern-*.tar.gz' -printf '%T@ %p\n' |
      sort -nr |
      tail -n +$((BACKUP_KEEP + 1)) |
      cut -d' ' -f2-
  )
  if (( ${#OLD_BACKUPS[@]} > 0 )); then
    for old_archive in "${OLD_BACKUPS[@]}"; do
      rm -f -- "$old_archive" "${old_archive}.sha256" "${old_archive}.partial"
    done
    note "Rotated ${#OLD_BACKUPS[@]} old archive(s), keeping the newest $BACKUP_KEEP."
  fi
fi

# The single line on stdout that callers consume.
log "$ARCHIVE"
