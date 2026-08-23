#!/usr/bin/env bash
# fs.sh — Cross-platform File System Metadata and Utility Functions
# Supports macOS (BSD stat) and Linux (GNU stat).
# No `set -e`: PreToolUse exit 1 is fail-open. Callers choose errexit.
set -uo pipefail

# Get octal file mode (e.g. "600", "755")
fs_get_mode() {
  local p="$1"
  stat -f '%Lp' "$p" 2>/dev/null || stat -c '%a' "$p" 2>/dev/null || printf 'unknown'
}

# Get modification time in epoch seconds
fs_get_mtime() {
  local p="$1"
  stat -f '%m' "$p" 2>/dev/null || stat -c '%Y' "$p" 2>/dev/null || printf '0'
}

# Get hard link count (nlink)
fs_get_nlink() {
  local p="$1"
  stat -f '%l' "$p" 2>/dev/null || stat -c '%h' "$p" 2>/dev/null || printf '0'
}

# Get file owner username
fs_get_owner() {
  local p="$1"
  stat -f '%Su' "$p" 2>/dev/null || stat -c '%U' "$p" 2>/dev/null || printf 'unknown'
}

# Get file size in bytes
fs_get_size() {
  local p="$1"
  if command -v stat >/dev/null 2>&1; then
    stat -f '%z' "$p" 2>/dev/null || stat -c '%s' "$p" 2>/dev/null || wc -c < "$p" 2>/dev/null | tr -d '[:space:]'
  else
    wc -c < "$p" 2>/dev/null | tr -d '[:space:]'
  fi
}
