#!/usr/bin/env bash
# Regression tests for the .env parser in scripts/lib.sh.
#
# The parser must resolve a key exactly the way `docker compose` does, because
# preflight.sh validates those values. Any divergence means a configuration
# Compose accepts gets rejected, or worse, something else gets validated.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

FIXTURE="$(mktemp)"
trap 'rm -f "$FIXTURE"' EXIT
ENV_FILE="$FIXTURE"

cat > "$FIXTURE" <<'EOF'
# a comment
APP_DOMAIN="quoted.example.com"
CADDY_EMAIL=
export TZ=Europe/Berlin
INLINE=value # trailing comment
HASH=pa#ss
SINGLE='sq'
SPACED   =   spaced value
DUP=first
DUP=second
BASE=example.com
DERIVED=chat.${BASE}
BARE=www.$BASE
SELF=$SELF
EMPTY_SET=
EOF

FAILURES=0

expect() {
  local key="$1"
  local want="$2"
  local got

  got="$(env_value "$key" || true)"

  if [[ "$got" == "$want" ]]; then
    printf 'ok   %-12s [%s]\n' "$key" "$got"
  else
    printf 'FAIL %-12s want=[%s] got=[%s]\n' "$key" "$want" "$got" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

expect APP_DOMAIN "quoted.example.com"
expect CADDY_EMAIL ""
expect TZ "Europe/Berlin"
expect INLINE "value"
expect HASH "pa#ss"
expect SINGLE "sq"
expect SPACED "spaced value"
expect DUP "second"
expect DERIVED "chat.example.com"
expect BARE "www.example.com"
expect SELF ""
expect EMPTY_SET ""

if env_value DEFINITELY_NOT_SET >/dev/null 2>&1; then
  printf 'FAIL %-12s expected the key to be absent\n' DEFINITELY_NOT_SET >&2
  FAILURES=$((FAILURES + 1))
else
  printf 'ok   %-12s <absent>\n' DEFINITELY_NOT_SET
fi

# A file edited on Windows must not leak a carriage return into the value.
printf 'CRLF=yes\r\n' > "$FIXTURE"
expect CRLF "yes"

if (( FAILURES > 0 )); then
  printf '\n%d assertion(s) failed.\n' "$FAILURES" >&2
  exit 1
fi

printf '\nAll .env parser assertions passed.\n'
