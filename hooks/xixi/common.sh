#!/usr/bin/env bash
# common.sh — shared path rules for _xixi clipboard delivery hooks.
# Sourced by restrict-write.sh and copy-on-write.sh (not executed alone).
#
# Allowed Write paths (exactly under /tmp, no subdirs, no extensions, no .., no symlinks):
#   /tmp/xixi-prompt-<id>
# where <id> is exactly 8 chars from [A-Za-z0-9]
#
# Fixed /tmp/xixi-prompt (no id) is NOT allowed — avoids concurrent overwrites.

# Returns 0 if path is allowed for _xixi Write delivery.
is_allowed_xixi_path() {
  local p="$1"
  if [ -z "$p" ] || [[ "$p" == *..* ]] || [[ "$p" == *$'\n'* ]] || [[ "$p" == *$'\r'* ]] || [ -L "$p" ]; then
    # [ -L "$p" ] rejects symlinks — a pre-created /tmp/xixi-prompt-<id> symlink is
    # the TOCTOU vector (grill F3): the Write tool would follow it to another target.
    # NOTE: tests the path itself, not /tmp (which is itself a symlink on macOS).
    return 1
  fi
  local dir base
  dir=$(dirname -- "$p")
  base=$(basename -- "$p")
  if [ "$dir" != "/tmp" ]; then
    return 1
  fi
  case "$base" in
    xixi-prompt-[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# True if agent_type identifies the _xixi subagent.
is_xixi_agent() {
  case "${1:-}" in
    _xixi|xixi) return 0 ;;
    *) return 1 ;;
  esac
}

# Atomically reserve a fresh non-symlink path for _xixi delivery (audit TOCTOU).
# Uses Python O_CREAT|O_EXCL|O_NOFOLLOW when available; fails closed on race.
# Returns 0 if path did not exist and was created as an empty regular file (ready for Write overwrite)
# or if path still does not exist and we cannot create (caller may still block on -e).
# Strategy: try exclusive create; if success, leave empty file so Write overwrites inode...
# WAIT: if we create empty file, restrict-write currently blocks -e. So reserve means:
# we create exclusively then DELETE before allow? That reopens race.
# Better: exclusive create empty, allow Write to overwrite same path without following symlink
# because path now is a regular file we created — Write tools typically open O_WRONLY|O_TRUNC
# on existing path without replacing inode with symlink follow to other target... 
# Actually if attacker replaces our regular file with symlink between create and Write, still race.
# Best effort: O_EXCL create + keep the file so path is occupied as regular file; change gate to
# allow existing file ONLY if it is a regular empty file we just created (size 0, not symlink).
reserve_xixi_path() {
  local p="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$p" <<'PY'
import os, sys
path = sys.argv[1]
flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
# O_NOFOLLOW where available (POSIX/macOS/Linux)
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
try:
    fd = os.open(path, flags, 0o600)
    os.close(fd)
    sys.exit(0)
except FileExistsError:
    sys.exit(1)
except OSError:
    sys.exit(1)
PY
    return $?
  fi
  # Fallback: bash cannot O_NOFOLLOW; refuse to reserve (caller fail-closed if exists)
  if [ -e "$p" ] || [ -L "$p" ]; then
    return 1
  fi
  # best-effort exclusive via set -o noclobber
  (set -C; : >"$p") 2>/dev/null || return 1
  return 0
}
