#!/usr/bin/env bash
# copy-prompt.sh — copy stdin to the system clipboard (cross-platform)
# Used by the _xixi subagent. Reads the refined prompt from stdin; takes no args.
# Exit 0 on success, non-zero if no clipboard backend is available.
set -euo pipefail

# Fixed absolute paths only (grill F27 / audit). No PATH fallback — a writable
# PATH entry could plant a rogue pbcopy and steal refined prompts.
try_exec() {
  local bin="$1"; shift || true
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    # Prefer root-owned system binaries when stat is available.
    # Select the stat dialect by platform instead of trying BSD first: GNU stat
    # reads -f as --file-system and PRINTS filesystem details before failing, so a
    # BSD-first `||` chain concatenates that output with the real answer and the
    # comparison below rejects a legitimate Linux backend (audit #19).
    if command -v stat >/dev/null 2>&1; then
      local owner
      if [ "$(uname -s)" = "Darwin" ]; then
        owner=$(stat -f %Su "$bin" 2>/dev/null) || owner=""
      else
        owner=$(stat -c %U "$bin" 2>/dev/null) || owner=""
      fi
      case "$owner" in
        root|"") ;;
        *) echo "copy-prompt.sh: refusing non-root clipboard binary: $bin (owner=$owner)" >&2; return 1 ;;
      esac
    fi
    exec "$bin" "$@"
  fi
  return 1
}

try_exec /usr/bin/pbcopy \
  || try_exec /usr/bin/wl-copy \
  || try_exec /usr/local/bin/wl-copy \
  || try_exec /usr/bin/xclip -selection clipboard \
  || try_exec /usr/local/bin/xclip -selection clipboard \
  || {
    echo "copy-prompt.sh: no trusted clipboard backend at fixed paths (pbcopy / wl-copy / xclip)" >&2
    exit 1
  }
