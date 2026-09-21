#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

docker compose config --quiet
docker compose ps

if docker compose exec -T sillytavern node src/healthcheck.js >/dev/null 2>&1; then
  echo "SillyTavern health check: OK"
else
  echo "SillyTavern health check: not ready or unhealthy" >&2
  exit 1
fi

