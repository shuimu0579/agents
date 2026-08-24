#!/usr/bin/env bash
# common.sh — shared path rules for _xixi clipboard delivery hooks (Facade).
# Sourced by restrict-write.sh and copy-on-write.sh.
set -euo pipefail

COMMON_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_DIR="${HOOK_LIB_DIR:-${COMMON_DIR}/../lib}"
if [[ ! -f "${LIB_DIR}/xixi.sh" ]]; then
  LIB_DIR="${HOME}/.claude/agents/hooks/lib"
fi

if [[ -f "${LIB_DIR}/core.sh" ]]; then
  source "${LIB_DIR}/core.sh"
fi
if [[ -f "${LIB_DIR}/xixi.sh" ]]; then
  source "${LIB_DIR}/xixi.sh"
fi

if ! declare -F xixi_is_allowed_path >/dev/null 2>&1; then
  echo "[xixi-hook] BLOCKED: required xixi.sh library missing" >&2
  return 1 2>/dev/null || exit 2
fi

is_allowed_xixi_path() {
  xixi_is_allowed_path "$@"
}

is_xixi_agent() {
  xixi_is_agent "$@"
}

reserve_xixi_path() {
  xixi_reserve_and_validate "$@"
}

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
if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
    sys.exit(1)
if st.st_size != 0 or st.st_nlink != 1 or st.st_uid != os.getuid() or (st.st_mode & stat.S_IWOTH):
    sys.exit(1)
sys.exit(0)
PY
}
