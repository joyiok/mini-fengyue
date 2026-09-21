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

if [[ ! -f "$ENV_FILE" ]]; then
  die "Missing .env. Run: cp .env.example .env, then edit it."
fi

if [[ ! -f config/config.yaml.example ]]; then
  die "config/config.yaml.example is missing. The deployment profile is the source of truth for config/config.yaml."
fi

if [[ ! -f config/config.yaml ]]; then
  warn "config/config.yaml does not exist yet; scripts/install.sh creates it from config/config.yaml.example."
fi

# -- .env permissions --------------------------------------------------------
if have stat; then
  ENV_MODE="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)"
  if [[ -n "$ENV_MODE" && "$ENV_MODE" != "600" ]]; then
    warn "$ENV_FILE mode is $ENV_MODE. It holds your domain and rotation settings; run: chmod 600 $ENV_FILE"
  fi
fi

# -- APP_DOMAIN --------------------------------------------------------------
# Validates one host token. Reports warnings only; every hard failure happens in
# validate_app_domain below, which knows whether tokens were combined.
validate_single_domain() {
  local value="$1"
  local target host port

  # Port-only form: plain HTTP on that port, no hostname-based certificates.
  if [[ "$value" =~ ^:[0-9]+$ ]]; then
    warn "APP_DOMAIN=$value serves this host on that port without automatic public HTTPS."
    warn "Use a real DNS name for an internet-facing deployment."
    return 0
  fi

  target="$value"
  if [[ "$target" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
    warn "APP_DOMAIN should be a bare hostname; the '${target%%://*}://' scheme is unnecessary."
    target="${target#*://}"
  fi

  if [[ "$target" == */* || "$target" == *"?"* || "$target" == *"#"* || "$target" == *[[:space:]]* ]]; then
    die "APP_DOMAIN must not contain a path, query, fragment or whitespace: $value"
  fi

  if [[ "$target" == *"*"* ]]; then
    die "APP_DOMAIN must not contain a wildcard: $value"
  fi

  if [[ "$target" == *..* ]]; then
    die "APP_DOMAIN contains an empty label: $value"
  fi

  host="$target"
  port=""
  if [[ "$target" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  fi

  if [[ ! "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    die "APP_DOMAIN is not a valid hostname (use e.g. chat.example.com or :80): $value"
  fi

  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "APP_DOMAIN=$host is an IP address. Public certificate issuance will fail;"
    warn "prefer APP_DOMAIN=:80 for a private or IP-only test."
  elif [[ "$host" != *.* && "$host" != "localhost" ]]; then
    warn "APP_DOMAIN=$host is not a fully qualified domain name; automatic HTTPS needs one."
  fi

  if [[ -n "$port" && "$port" != "443" ]]; then
    warn "APP_DOMAIN declares port $port; Caddy serves HTTPS there, while Docker still publishes host ports 80 and 443."
  fi

  return 0
}

# Accepts one host or a comma/whitespace separated list of hosts, for example
# "shuai.gay, www.shuai.gay". Caddy serves every listed host and obtains a
# certificate for each, so a host that resolves here but is left out would end up
# without TLS.
validate_app_domain() {
  local raw="$1"
  local token
  local -a tokens=()

  if [[ -z "$raw" ]]; then
    die "APP_DOMAIN must not be empty."
  fi

  mapfile -t tokens < <(printf '%s\n' "${raw//,/ }" | tr -s '[:space:]' '\n' | sed '/^$/d')

  if (( ${#tokens[@]} == 0 )); then
    die "APP_DOMAIN must not be empty."
  fi

  for token in "${tokens[@]}"; do
    if [[ "$token" =~ ^:[0-9]+$ ]] && (( ${#tokens[@]} > 1 )); then
      die "The port-only form ($token) cannot be combined with hostnames in APP_DOMAIN."
    fi
  done

  for token in "${tokens[@]}"; do
    validate_single_domain "$token"
  done

  return 0
}

APP_DOMAIN_VALUE="$(setting_or APP_DOMAIN ':80')"
validate_app_domain "$APP_DOMAIN_VALUE"

# -- image source ------------------------------------------------------------
SILLYTAVERN_IMAGE_VALUE="$(setting_or SILLYTAVERN_IMAGE 'ghcr.io/sillytavern/sillytavern')"
if [[ -z "$SILLYTAVERN_IMAGE_VALUE" ]]; then
  die "SILLYTAVERN_IMAGE must not be empty."
fi
# A tag after the last slash would be concatenated with SILLYTAVERN_VERSION and
# produce an invalid reference like image:1.2:1.3.
if [[ "${SILLYTAVERN_IMAGE_VALUE##*/}" == *:* ]]; then
  die "SILLYTAVERN_IMAGE must not include a tag; set the tag via SILLYTAVERN_VERSION instead (got: $SILLYTAVERN_IMAGE_VALUE)."
fi

# -- host port used only for local troubleshooting ---------------------------
ST_LOCAL_PORT_VALUE="$(setting_or ST_LOCAL_PORT '127.0.0.1:8000')"
if [[ ! "$ST_LOCAL_PORT_VALUE" =~ ^(127\.0\.0\.1|localhost|\[::1\]):[0-9]+$ ]]; then
  printf 'Error: ST_LOCAL_PORT must stay bound to loopback (for example 127.0.0.1:8000).\n' >&2
  printf 'Refusing a direct public SillyTavern port mapping: %s\n' "$ST_LOCAL_PORT_VALUE" >&2
  exit 1
fi

# -- uid/gid and backup rotation --------------------------------------------
for value_name in PUID PGID; do
  value="$(setting_or "$value_name" '')"
  if [[ -n "$value" && ! "$value" =~ ^[0-9]+$ ]]; then
    die "$value_name must be numeric when set (got: $value)."
  fi
done

BACKUP_KEEP_VALUE="$(setting_or BACKUP_KEEP 14)"
if [[ ! "$BACKUP_KEEP_VALUE" =~ ^[0-9]+$ ]]; then
  die "BACKUP_KEEP must be a non-negative integer (got: $BACKUP_KEEP_VALUE)."
fi

# -- soft host port conflicts ------------------------------------------------
# Our own running Caddy owns 80/443, which is not a conflict.
# Note: capture command output before matching it. `producer | grep -q` makes the
# producer die from SIGPIPE once grep matches, which pipefail reports as failure.
caddy_is_ours() {
  local services

  have docker || return 1
  services="$(docker compose ps --status running --services 2>/dev/null || true)"
  grep -qx 'caddy' <<<"$services"
}

check_host_port() {
  local port="$1"
  local listeners

  have ss || return 0
  listeners="$(ss -ltnH "sport = :$port" 2>/dev/null || true)"
  if [[ -n "$listeners" ]]; then
    if caddy_is_ours; then
      return 0
    fi
    warn "Host port $port is already in use. If that is not this Compose stack, Caddy will fail to start."
  fi
}

check_host_port 80
check_host_port 443

# -- Caddy storage ownership -------------------------------------------------
# An older version of this bundle ran the Caddy container as root, which leaves
# root-owned files that the normal user can neither read nor remove.
if caddy_storage_is_unusable; then
  warn "./caddy is not usable by the container user (PUID:PGID = $(setting_or PUID 1000):$(setting_or PGID 1000))."
  warn "Caddy would fail to create /data/caddy and silently store no certificates, and"
  warn "backups and uninstall would fail too. Fix it with:"
  warn "  ./scripts/install.sh          # hands the directory to PUID:PGID automatically, or"
  warn "  sudo chown -R $(setting_or PUID 1000):$(setting_or PGID 1000) caddy"
fi

# -- final Compose validation ------------------------------------------------
docker compose config --quiet

log "Preflight: OK (APP_DOMAIN=${APP_DOMAIN_VALUE}, SILLYTAVERN_IMAGE=${SILLYTAVERN_IMAGE_VALUE}, ST_LOCAL_PORT=${ST_LOCAL_PORT_VALUE}, BACKUP_KEEP=${BACKUP_KEEP_VALUE})"
