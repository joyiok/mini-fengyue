#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash ./scripts/preflight.sh
./scripts/backup.sh
docker compose pull sillytavern caddy
docker compose up -d --remove-orphans
docker compose ps
