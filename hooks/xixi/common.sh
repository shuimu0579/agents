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

# Atomically reserve a fresh path for _xixi delivery.
# Security policy: if we cannot create with O_CREAT|O_EXCL|O_NOFOLLOW, fail closed.
reserve_xixi_path() {
  local p="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  python3 - "$p" <<'PY'
import os, sys
path = sys.argv[1]
flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
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
}

# Validate the inode we just reserved before letting the Write tool truncate it.
# Requirements:
# - regular file
# - size 0
# - exactly one hard link
# - owned by the current uid
# - not world-writable
# - not a symlink
assert_reserved_xixi_file() {
  local p="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  python3 - "$p" <<'PY'
import os, stat, sys

path = sys.argv[1]
try:
    st = os.lstat(path)
except OSError:
    sys.exit(1)

if stat.S_ISLNK(st.st_mode):
    sys.exit(1)
if not stat.S_ISREG(st.st_mode):
    sys.exit(1)
if st.st_size != 0:
    sys.exit(1)
if st.st_nlink != 1:
    sys.exit(1)
if st.st_uid != os.getuid():
    sys.exit(1)
if st.st_mode & stat.S_IWOTH:
    sys.exit(1)
sys.exit(0)
PY
}
