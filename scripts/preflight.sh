#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required. Install Docker Engine and the Compose plugin first." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required (docker compose)." >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "Missing .env. Run: cp .env.example .env, then edit it." >&2
  exit 1
fi

env_value() {
  local key="$1"
  awk -F= -v key="$key" '
    $0 !~ /^[[:space:]]*#/ && $1 == key {
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' .env
}

APP_DOMAIN_VALUE="$(env_value APP_DOMAIN)"
ST_LOCAL_PORT_VALUE="$(env_value ST_LOCAL_PORT)"
PUID_VALUE="$(env_value PUID)"
PGID_VALUE="$(env_value PGID)"

if [[ -z "$APP_DOMAIN_VALUE" ]]; then
  echo "APP_DOMAIN must not be empty." >&2
  exit 1
fi

if [[ "$APP_DOMAIN_VALUE" == ":80" || "$APP_DOMAIN_VALUE" == ":443" ]]; then
  echo "Warning: APP_DOMAIN=$APP_DOMAIN_VALUE disables hostname-based automatic HTTPS." >&2
  echo "Use a real DNS name for an internet-facing deployment." >&2
fi

ST_LOCAL_PORT_VALUE="${ST_LOCAL_PORT_VALUE:-127.0.0.1:8000}"
if [[ ! "$ST_LOCAL_PORT_VALUE" =~ ^(127\.0\.0\.1|localhost|\[::1\]):[0-9]+$ ]]; then
  echo "ST_LOCAL_PORT must stay bound to loopback (for example 127.0.0.1:8000)." >&2
  echo "Refusing a direct public SillyTavern port mapping: $ST_LOCAL_PORT_VALUE" >&2
  exit 1
fi

for value_name in PUID_VALUE PGID_VALUE; do
  value="${!value_name}"
  if [[ -n "$value" && ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$value_name must be numeric when set." >&2
    exit 1
  fi
done

docker compose config --quiet
echo "Preflight: OK"
