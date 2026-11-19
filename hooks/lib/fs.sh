#!/usr/bin/env bash
# fs.sh — Cross-platform File System Metadata and Utility Functions
# Supports macOS (BSD stat) and Linux (GNU stat).
# No `set -e`: PreToolUse exit 1 is fail-open. Callers choose errexit.
set -uo pipefail

_IS_DARWIN=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  _IS_DARWIN=1
fi

# Get octal file mode (e.g. "600", "755")
fs_get_mode() {
  local p="$1"
  if [[ -n "$_IS_DARWIN" ]]; then
    stat -f '%Lp' "$p" 2>/dev/null || printf 'unknown'
  else
    stat -c '%a' "$p" 2>/dev/null || stat -f '%Lp' "$p" 2>/dev/null || printf 'unknown'
  fi
}

# Get modification time in epoch seconds
fs_get_mtime() {
  local p="$1"
  if [[ -n "$_IS_DARWIN" ]]; then
    stat -f '%m' "$p" 2>/dev/null || printf '0'
  else
    stat -c '%Y' "$p" 2>/dev/null || stat -f '%m' "$p" 2>/dev/null || printf '0'
  fi
}



