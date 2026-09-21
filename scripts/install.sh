#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

if ! have docker; then
  die "Docker is required. Install Docker Engine and the Compose plugin first."
fi

if ! docker compose version >/dev/null 2>&1; then
  die "Docker Compose v2 is required (docker compose)."
fi

mkdir -p config data plugins extensions caddy/data caddy/config backups

# The Caddy container runs as PUID/PGID and SillyTavern's entrypoint fixes up its
# own directories, but nothing fixes ./caddy. Installing as root is the normal
# case on a fresh server, and the directories just created would be root-owned:
# Caddy would then fail to create /data/caddy and silently store no
# certificates. Hand the runtime directories to the container user explicitly.
PUID_VALUE="$(setting_or PUID 1000)"
PGID_VALUE="$(setting_or PGID 1000)"

if [[ "$(id -u)" == "0" && ( "$PUID_VALUE" != "0" || "$PGID_VALUE" != "0" ) ]]; then
  log "Running as root: giving the runtime directories to ${PUID_VALUE}:${PGID_VALUE}..."
  chown "$PUID_VALUE:$PGID_VALUE" config data plugins extensions caddy backups
  chown -R "$PUID_VALUE:$PGID_VALUE" caddy
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  log "Created .env from .env.example. Edit APP_DOMAIN before exposing this deployment."
fi

# config/config.yaml is generated from the tracked profile and rewritten by
# SillyTavern on every start, which is why it is not tracked by Git.
if [[ ! -f config/config.yaml ]]; then
  if [[ ! -f config/config.yaml.example ]]; then
    die "config/config.yaml.example is missing from the repository."
  fi
  cp config/config.yaml.example config/config.yaml
  log "Created config/config.yaml from config/config.yaml.example."
fi

bash ./scripts/preflight.sh

if [[ "${SKIP_PULL:-}" == "YES" ]]; then
  warn "Skipping the image pull (SKIP_PULL=YES); using whatever is already local."
else
  pull_images sillytavern caddy || die "Could not pull the required images; see the hints above."
fi

# Caddy runs as PUID/PGID. A ./caddy left behind by an older run as root would
# stop it from storing certificates, so normalize ownership before starting.
if caddy_storage_is_unusable; then
  log "Fixing ownership of ./caddy (root-owned leftovers from an earlier run)..."
  if ! chown_via_container "$ROOT_DIR/caddy"; then
    warn "Could not normalize ./caddy automatically. Caddy may fail to write certificates."
    warn "Fix it manually with: sudo chown -R $(id -u):$(id -g) caddy"
  fi
fi

# --- first start: SillyTavern alone -----------------------------------------
# Caddy waits for SillyTavern to be healthy, and the very first start is
# refused on purpose: on an empty data root SillyTavern always creates a
# password-less `default-user` admin, its startup security check then exits, and
# the container restart-loops. Start it alone, give that account a password,
# then bring the whole stack up.
log "Initializing SillyTavern data (the first start exits by design until the admin has a password)..."
docker compose up -d sillytavern

log "Waiting for the initial account to be created..."
INIT_DEADLINE=$(( SECONDS + 120 ))
until compgen -G "data/_storage/*" >/dev/null; do
  if (( SECONDS >= INIT_DEADLINE )); then
    docker compose logs --tail=50 sillytavern || true
    die "SillyTavern did not create its initial account within 120s."
  fi
  sleep 3
done

ADMIN_PASSWORD=""
if grep -qs '"password":""' data/_storage/*; then
  ADMIN_PASSWORD="$(generate_admin_password)"
  log "Setting a password for the initial admin account..."
  docker compose stop sillytavern >/dev/null

  # Run as the configured uid/gid so the one-off container cannot leave
  # root-owned files in the data directory.
  if ! docker compose run --rm --no-deps \
    --user "$(setting_or PUID 1000):$(setting_or PGID 1000)" \
    --entrypoint node sillytavern recover.js default-user "$ADMIN_PASSWORD" >/dev/null 2>&1; then
    docker compose up -d
    die "Could not set the initial admin password. Inspect: docker compose logs --tail=50 sillytavern"
  fi
fi

docker compose up -d

log "Waiting for SillyTavern to pass its health check..."
HEALTH_DEADLINE=$(( SECONDS + 180 ))
while ! docker compose exec -T sillytavern node src/healthcheck.js >/dev/null 2>&1; do
  if (( SECONDS >= HEALTH_DEADLINE )); then
    docker compose ps
    die "SillyTavern did not become healthy within 180s. Inspect: docker compose logs --tail=100 sillytavern"
  fi
  sleep 5
done

docker compose ps

APP_DOMAIN_VALUE="$(setting_or APP_DOMAIN ':80')"
PRIMARY_DOMAIN_VALUE="$(primary_domain "$APP_DOMAIN_VALUE" || true)"
case "$PRIMARY_DOMAIN_VALUE" in
  :80)
    log "Ready: http://<server-ip>/"
    ;;
  :*)
    log "Ready: http://<server-ip>${PRIMARY_DOMAIN_VALUE}/"
    ;;
  *)
    log "Ready: https://${PRIMARY_DOMAIN_VALUE}/ (once DNS points here and Caddy has issued its certificate)"
    if [[ "$APP_DOMAIN_VALUE" != "$PRIMARY_DOMAIN_VALUE" ]]; then
      log "Also served with their own certificates: $APP_DOMAIN_VALUE"
    fi
    ;;
esac

if [[ -n "$ADMIN_PASSWORD" ]]; then
  printf '\n'
  log "----------------------------------------------------------"
  log "  初始管理员账户:  default-user"
  log "  初始密码:        $ADMIN_PASSWORD"
  log "  请立刻保存到密码管理器，并在登录后修改它。"
  log "  忘了也可以在服务器上重设："
  log "    docker compose exec sillytavern node recover.js default-user <新密码>"
  log "----------------------------------------------------------"
  printf '\n'
else
  log "The admin account already had a password; it was left unchanged."
fi
