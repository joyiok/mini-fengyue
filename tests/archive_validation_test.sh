#!/usr/bin/env bash
# Regression tests for validate_backup_archive() in scripts/lib.sh.
#
# The large-archive case exists because of a real bug: reading the listing with
# `tar -tzf "$a" | grep -q pattern` made grep exit at the first match, tar die
# from SIGPIPE ("write error"), and `set -o pipefail` turn that into a failed
# pipeline. Small archives hid it because tar finished writing first; a realistic
# one did not, and a perfectly good backup was rejected as "not a Mini Story
# backup" on the first real restore.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

FAILURES=0

pass() { printf 'ok   %s\n' "$1"; }

fail() {
  printf 'FAIL %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

assert_accepts() {
  if validate_backup_archive "$1" 2>/dev/null; then
    pass "$2"
  else
    fail "$2"
  fi
}

assert_rejects() {
  if validate_backup_archive "$1" 2>/dev/null; then
    fail "$2"
  else
    pass "$2"
  fi
}

# A small but valid archive: the shape backup.sh produces.
mkdir -p "$WORK_DIR/small/config" "$WORK_DIR/small/data"
printf 'profile\n' > "$WORK_DIR/small/config/config.yaml"
tar -czf "$WORK_DIR/small.tar.gz" -C "$WORK_DIR/small" ./config ./data

# The same shape, with enough entries that tar is still streaming its listing
# when an early-exiting reader walks away. The trigger is the number of entries,
# not the byte size: 500 entries already reproduce it reliably, and a real data
# directory holds thousands.
mkdir -p "$WORK_DIR/many/config" "$WORK_DIR/many/data/chats"
printf 'profile\n' > "$WORK_DIR/many/config/config.yaml"
for i in $(seq 1 2000); do
  : > "$WORK_DIR/many/data/chats/chat_$i.jsonl"
done
tar -czf "$WORK_DIR/many.tar.gz" -C "$WORK_DIR/many" ./config ./data

# A file that is not an archive at all.
printf 'this is not a tarball\n' > "$WORK_DIR/garbage.tar.gz"

# A perfectly valid archive that simply is not one of ours.
mkdir -p "$WORK_DIR/foreign"
printf 'hello\n' > "$WORK_DIR/foreign/hello.txt"
tar -czf "$WORK_DIR/foreign.tar.gz" -C "$WORK_DIR/foreign" ./hello.txt

# An archive carrying a parent-directory path, which must never be extracted.
mkdir -p "$WORK_DIR/evil/data"
printf 'x\n' > "$WORK_DIR/evil/data/file"
tar -czf "$WORK_DIR/evil.tar.gz" -C "$WORK_DIR/evil" ./data \
  --transform 's|^\./data/file$|../escaped|' 2>/dev/null || true

assert_accepts "$WORK_DIR/small.tar.gz" "accepts a small valid archive"
assert_accepts "$WORK_DIR/many.tar.gz" "accepts a many-entry valid archive (SIGPIPE regression)"
assert_rejects "$WORK_DIR/garbage.tar.gz" "rejects a file that is not an archive"
assert_rejects "$WORK_DIR/foreign.tar.gz" "rejects an unrelated archive"

if tar -tzf "$WORK_DIR/evil.tar.gz" 2>/dev/null | grep -q '\.\./'; then
  assert_rejects "$WORK_DIR/evil.tar.gz" "rejects parent-directory paths"
else
  printf 'skip %s\n' "parent-directory case (this tar could not craft it)"
fi

if (( FAILURES > 0 )); then
  printf '\n%d assertion(s) failed.\n' "$FAILURES" >&2
  exit 1
fi

printf '\nAll archive validation assertions passed.\n'
