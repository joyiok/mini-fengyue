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

mkdir -p config data plugins extensions caddy/data caddy/config backups

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  echo "Created .env from .env.example. Edit APP_DOMAIN before using a public domain."
fi

docker compose pull
docker compose up -d

echo
docker compose ps
echo
echo "SillyTavern is starting. Open APP_DOMAIN from .env after the health check passes."
echo "Create your private SillyTavern account on the first visit."
