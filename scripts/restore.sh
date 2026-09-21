#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

ARCHIVE="${1:-}"

if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  printf 'Usage: %s backups/story-tavern-YYYYmmdd-HHMMSS.tar.gz\n' "$0" >&2
  exit 2
fi

# 1. Read the archive end to end and run every safety check on it before
#    touching anything: valid gzip tar, no absolute/parent paths, and it really
#    looks like one of our backups.
validate_backup_archive "$ARCHIVE" || exit 1

# 2. Verify the checksum that scripts/backup.sh wrote next to the archive.
if [[ -f "${ARCHIVE}.sha256" ]]; then
  EXPECTED_SUM="$(awk 'NR==1 {print $1}' "${ARCHIVE}.sha256")"
  ACTUAL_SUM="$(sha256_of "$ARCHIVE")"
  if [[ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]]; then
    die "Checksum mismatch for $ARCHIVE (expected $EXPECTED_SUM, got $ACTUAL_SUM). Refusing to restore."
  fi
  log "Checksum verified: $ARCHIVE"
else
  warn "No ${ARCHIVE}.sha256 found; restoring without integrity verification."
fi

# 3. Checking a backup must not require the confirmation flag or a running stack.
if [[ "${VALIDATE_ONLY:-}" == "YES" ]]; then
  log "Archive is a valid, intact Mini Story backup: $ARCHIVE"
  exit 0
fi

# 4. Restoring overwrites private data, so it needs an explicit confirmation.
if [[ "${CONFIRM_RESTORE:-}" != "YES" ]]; then
  printf 'Restore overwrites config and private data. Set CONFIRM_RESTORE=YES to continue.\n' >&2
  printf 'To only check the archive: VALIDATE_ONLY=YES %s %s\n' "$0" "$ARCHIVE" >&2
  exit 1
fi

# 5. Fail before stopping anything if the target environment is not deployable.
bash ./scripts/preflight.sh

# 6. Keep a way back: archive the current state first.
SAFETY_ARCHIVE=""
if [[ "${SKIP_SAFETY_BACKUP:-}" == "YES" ]]; then
  warn "Skipping the pre-restore safety backup (SKIP_SAFETY_BACKUP=YES)."
else
  log "Creating a safety backup of the current state..."
  if ! SAFETY_ARCHIVE="$(./scripts/backup.sh | tail -n1)"; then
    die "The pre-restore safety backup failed; aborting without changing any data."
  fi
  if [[ ! -f "$SAFETY_ARCHIVE" ]]; then
    die "The pre-restore safety backup did not produce a usable archive; aborting."
  fi
  log "Safety backup: $SAFETY_ARCHIVE"
fi

docker compose down

# If extraction dies halfway, bring the stack back up and point at the safety
# archive instead of leaving a down deployment and a half-restored data tree.
restore_failed() {
  printf 'Error: extraction failed; the data tree may be incomplete.\n' >&2
  if [[ -n "$SAFETY_ARCHIVE" ]]; then
    printf 'Recover with: CONFIRM_RESTORE=YES SKIP_SAFETY_BACKUP=YES %s %s\n' "$0" "$SAFETY_ARCHIVE" >&2
  fi
  docker compose up -d || true
}
trap restore_failed ERR

# 7. Restore private data only. Caddyfile, docker-compose.yml and
# config/config.yaml.example stay under Git control so a restore cannot
# silently downgrade the deployment configuration.
tar -xzf "$ARCHIVE" -C "$ROOT_DIR" \
  --no-same-owner --no-same-permissions \
  --exclude='./docker-compose.yml' --exclude='docker-compose.yml' \
  --exclude='./Caddyfile' --exclude='Caddyfile' \
  --exclude='./config/config.yaml.example' --exclude='config/config.yaml.example'

trap - ERR

docker compose up -d
docker compose ps

# 8. Prove the restored stack actually serves traffic.
bash ./scripts/check.sh

log "Restore complete."
if [[ -n "$SAFETY_ARCHIVE" ]]; then
  log "To undo this restore: CONFIRM_RESTORE=YES SKIP_SAFETY_BACKUP=YES ./scripts/restore.sh $SAFETY_ARCHIVE"
fi
