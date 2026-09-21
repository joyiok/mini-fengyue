#!/usr/bin/env bash
# Shared helpers for the Mini Story deployment scripts.
#
# This file is meant to be sourced, not executed:
#   ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
#   cd "$ROOT_DIR"
#   source "$ROOT_DIR/scripts/lib.sh"
#
# Sourcing scripts must `cd "$ROOT_DIR"` first: ENV_FILE is resolved relative to
# the current directory.

# shellcheck shell=bash

ENV_FILE="${ENV_FILE:-.env}"

log() { printf '%s\n' "$*"; }

warn() { printf 'Warning: %s\n' "$*" >&2; }

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# Parsed .env contents: key -> value.
declare -A ENV_VALUES=()

# Read $ENV_FILE using the same rules Docker Compose applies:
#   * blank lines and lines starting with '#' are ignored
#   * an optional `export ` prefix
#   * `KEY = value`, with the key and value trimmed
#   * surrounding single or double quotes are stripped
#   * an unquoted value ends at the first whitespace-preceded '#'
#   * a repeated key overrides the earlier definition (last one wins)
#   * ${VAR} and $VAR references expand from keys defined earlier in the file
# Parsing .env with different rules than Compose is how a configuration Compose
# accepts turns into a rejected deployment, or the other way round.
load_env() {
  ENV_VALUES=()
  [[ -f "$ENV_FILE" ]] || return 1

  local line key value name ref depth

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"

    if [[ -z "$line" || "${line:0:1}" == "#" ]]; then
      continue
    fi

    if [[ "$line" == "export "* || "$line" == "export"$'\t'* ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi

    if [[ "$line" != *=* ]]; then
      continue
    fi

    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      continue
    fi

    value="${line#*=}"
    if [[ "$value" == \"* ]]; then
      value="${value#\"}"
      value="${value%%\"*}"
    elif [[ "$value" == \'* ]]; then
      value="${value#\'}"
      value="${value%%\'*}"
    else
      value="${value%%[[:space:]]#*}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
    fi

    # Expand references to keys defined earlier in the file. The depth cap keeps
    # a self-referencing value from looping forever.
    depth=0
    while [[ "$value" == *'$'* ]] && (( depth < 5 )); do
      if [[ "$value" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then
        name="${BASH_REMATCH[1]}"
      elif [[ "$value" =~ \$([A-Za-z_][A-Za-z0-9_]*) ]]; then
        name="${BASH_REMATCH[1]}"
      else
        break
      fi
      ref="${ENV_VALUES[$name]:-}"
      value="${value//\$\{$name\}/$ref}"
      value="${value//\$$name/$ref}"
      depth=$(( depth + 1 ))
    done

    ENV_VALUES["$key"]="$value"
  done < "$ENV_FILE"

  return 0
}

# Print the value of a key and return 0, or return 1 when the key is absent.
env_value() {
  local key="$1"

  load_env || return 1
  [[ -n "${ENV_VALUES[$key]+set}" ]] || return 1

  printf '%s\n' "${ENV_VALUES[$key]}"
  return 0
}

# Same as env_value, but falls back when the key is absent or empty.
env_value_or() {
  local key="$1"
  local fallback="$2"
  local value

  value="$(env_value "$key" || true)"
  printf '%s\n' "${value:-$fallback}"
}

# Resolve a setting the way `docker compose` resolves Compose variables: an
# explicit environment variable wins over .env, which wins over the default.
setting_or() {
  local name="$1"
  local fallback="$2"
  local current="${!name-}"

  if [[ -n "$current" ]]; then
    printf '%s\n' "$current"
    return 0
  fi

  env_value_or "$name" "$fallback"
}

# Print the SHA-256 digest of a file. Works with coreutils and with macOS.
sha256_of() {
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required to verify backups."
  fi
}

# Print a `sha256sum -c` compatible checksum line for a file. The path is kept
# as given, so verification works when run from the same directory.
sha256_line_of() {
  printf '%s  %s\n' "$(sha256_of "$1")" "$1"
}

# Validate that a file is a restorable Mini Story archive. Prints the reason to
# stderr and returns non-zero when it is not.
#
# The listing is read in one pass on purpose. Checking it with a pipeline such
# as `tar -tzf "$a" | grep -q pattern` is a trap: grep exits at the first match,
# tar then dies from SIGPIPE ("write error"), and `set -o pipefail` turns that
# into a failed pipeline. The result is inverted on large archives, where tar is
# still writing when grep leaves.
validate_backup_archive() {
  local archive="$1"
  local listing

  if ! listing="$(tar -tzf "$archive" 2>/dev/null)"; then
    printf 'Error: %s is not a valid gzip-compressed tar archive.\n' "$archive" >&2
    return 1
  fi

  if grep -Eq '(^/|(^|/)\.\.(\/|$))' <<<"$listing"; then
    printf 'Error: refusing an archive with absolute or parent-directory paths.\n' >&2
    return 1
  fi

  if ! grep -Eq '^\./(data|config)/' <<<"$listing"; then
    printf 'Error: %s contains no ./data or ./config entry; it does not look like a Mini Story backup.\n' "$archive" >&2
    return 1
  fi

  return 0
}

# Print the first host from an APP_DOMAIN value that may list several hosts
# separated by commas or whitespace.
primary_domain() {
  local value="${1//,/ }"
  local token

  while IFS= read -r token; do
    if [[ -n "$token" ]]; then
      printf '%s\n' "$token"
      return 0
    fi
  done < <(printf '%s\n' "$value" | tr -s '[:space:]' '\n')

  return 1
}

# Caddy must be able to read and write its storage under ./caddy. Ownership is
# judged for the container user (PUID/PGID), not for whoever runs this script:
# when install.sh runs as root, every directory looks writable here while the
# Caddy container still cannot create /data/caddy and silently fails to store
# certificates. Must be called with the repository root as the current directory.
caddy_storage_is_unusable() {
  local dir owner_uid owner_gid
  local expect_uid expect_gid

  expect_uid="$(setting_or PUID 1000)"
  expect_gid="$(setting_or PGID 1000)"

  for dir in caddy caddy/data caddy/config caddy/data/caddy caddy/config/caddy; do
    if [[ ! -e "$dir" ]]; then
      continue
    fi

    owner_uid="$(stat -c '%u' "$dir" 2>/dev/null || stat -f '%u' "$dir" 2>/dev/null || true)"
    owner_gid="$(stat -c '%g' "$dir" 2>/dev/null || stat -f '%g' "$dir" 2>/dev/null || true)"

    if [[ -n "$owner_uid" && ( "$owner_uid" != "$expect_uid" || "$owner_gid" != "$expect_gid" ) ]]; then
      return 0
    fi

    if [[ ! -r "$dir" || ! -w "$dir" ]]; then
      return 0
    fi
  done

  return 1
}

# chown a directory to PUID/PGID without needing sudo, by running chown inside a
# throwaway container. Reuses the Caddy image, which is already pulled.
chown_via_container() {
  local target="$1"
  local uid gid

  have docker || return 1
  [[ -e "$target" ]] || return 0

  uid="$(setting_or PUID 1000)"
  gid="$(setting_or PGID 1000)"

  docker run --rm -v "$(cd -- "$target" && pwd):/target" "${CADDY_IMAGE:-caddy:2-alpine}" \
    chown -R "$uid:$gid" /target >/dev/null 2>&1
}

# Generate a shell-safe random password for the initial admin account.
# 32 hex characters, so it survives being pasted into a shell or a URL.
generate_admin_password() {
  if have openssl; then
    openssl rand -hex 16
  else
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
  fi
}

# Pull images with one retry and an actionable failure message. A registry EOF
# is the most common install failure, and the raw daemon error explains nothing
# about what to do next.
pull_images() {
  local attempt

  for attempt in 1 2; do
    if docker compose pull "$@"; then
      return 0
    fi
    if (( attempt == 1 )); then
      warn "Image pull failed; retrying once (registry connections often time out transiently)."
      sleep 3
    fi
  done

  warn "Image pull failed twice. This is a registry or network problem, not a config problem."
  warn "The stack needs two images from two different registries:"
  warn "  ${SILLYTAVERN_IMAGE:-ghcr.io/sillytavern/sillytavern}:${SILLYTAVERN_VERSION:-latest}  (ghcr.io)"
  warn "  ${CADDY_IMAGE:-caddy:2-alpine}  (Docker Hub)"
  warn "Point the unreachable one at a mirror in .env, for example:"
  warn "  SILLYTAVERN_IMAGE=ghcr.nju.edu.cn/sillytavern/sillytavern   # mirrors ghcr.io"
  warn "  CADDY_IMAGE=docker.m.daocloud.io/library/caddy:2-alpine    # mirrors Docker Hub"
  warn "If the images are already present locally, skip the pull entirely:"
  warn "  SKIP_PULL=YES ./scripts/install.sh"
  return 1
}
