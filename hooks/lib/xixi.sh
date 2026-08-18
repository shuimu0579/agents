#!/usr/bin/env bash
# xixi.sh — Shared Path Rules and Atomic Sandbox Operations for _xixi Hooks
set -euo pipefail

# Returns 0 if path is allowed for _xixi Write delivery.
xixi_is_allowed_path() {
  local p="$1"
  if [ -z "$p" ] || [[ "$p" == *..* ]] || [[ "$p" == *$'\n'* ]] || [[ "$p" == *$'\r'* ]] || [ -L "$p" ]; then
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

# True if agent identifies the _xixi subagent.
xixi_is_agent() {
  case "${1:-}" in
    _xixi|xixi) return 0 ;;
    *) return 1 ;;
  esac
}

# Atomically reserve a fresh path and validate its inode properties in a single Python invocation.
# Security policy: fail closed if cannot create exclusively or fails inode validation.
xixi_reserve_and_validate() {
  local p="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  python3 - "$p" <<'PY'
import os, stat, sys

path = sys.argv[1]
flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW

try:
    fd = os.open(path, flags, 0o600)
except Exception:
    sys.exit(1)

try:
    fst = os.fstat(fd)
    lst = os.lstat(path)
    # Check that open descriptor matches filesystem path exactly
    if fst.st_ino != lst.st_ino or fst.st_dev != lst.st_dev:
        sys.exit(1)
    if stat.S_ISLNK(lst.st_mode) or not stat.S_ISREG(fst.st_mode):
        sys.exit(1)
    if fst.st_size != 0 or fst.st_nlink != 1:
        sys.exit(1)
    if fst.st_uid != os.getuid():
        sys.exit(1)
    if fst.st_mode & stat.S_IWOTH:
        sys.exit(1)
finally:
    try:
        os.close(fd)
    except OSError:
        pass

sys.exit(0)
PY
}

# Open with O_NOFOLLOW, validate size and link count, copy to clipboard via backend, and unlink.
xixi_copy_and_cleanup() {
  local p="$1" copy_script="$2" max_bytes="$3"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$p" "$copy_script" "$max_bytes" <<'PY'
import os, stat, subprocess, sys

path, copy_script, max_bytes = sys.argv[1], sys.argv[2], int(sys.argv[3])
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW

try:
    fd = os.open(path, flags)
except OSError:
    sys.exit(2)

try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        sys.exit(3)
    if st.st_nlink != 1:
        sys.exit(7)
    if st.st_size == 0:
        sys.exit(4)
    if st.st_size > max_bytes:
        sys.exit(5)
    data = os.read(fd, st.st_size)
finally:
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.unlink(path)
    except OSError:
        pass

if not (os.path.isfile(copy_script) and os.access(copy_script, os.X_OK)):
    sys.exit(15)
try:
    r = subprocess.run([copy_script], input=data, check=False)
    sys.exit(0 if r.returncode == 0 else 6)
except OSError:
    sys.exit(6)
PY
    return $?
  fi

  # Shell fallback if python3 is unavailable
  if [ -L "$p" ]; then
    return 10
  fi
  if [ ! -f "$p" ]; then
    return 11
  fi

  local nlink size
  nlink=$(stat -f '%l' "$p" 2>/dev/null || stat -c '%h' "$p" 2>/dev/null || printf 'unknown')
  [[ "$nlink" =~ ^[0-9]+$ ]] || return 17
  [ "$nlink" -eq 1 ] || { rm -f -- "$p" 2>/dev/null || true; return 18; }

  size=$(wc -c < "$p" | tr -d '[:space:]')
  [[ "$size" =~ ^[0-9]+$ ]] || return 12
  [ "$size" -eq 0 ] && { rm -f -- "$p" 2>/dev/null || true; return 13; }
  [ "$size" -gt "$max_bytes" ] && { rm -f -- "$p" 2>/dev/null || true; return 14; }
  [ -x "$copy_script" ] || { rm -f -- "$p" 2>/dev/null || true; return 15; }

  if "$copy_script" < "$p"; then
    rm -f -- "$p" 2>/dev/null || true
    return 0
  fi
  rm -f -- "$p" 2>/dev/null || true
  return 16
}
