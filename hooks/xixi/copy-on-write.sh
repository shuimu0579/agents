#!/usr/bin/env bash
# copy-on-write.sh — PostToolUse hook for the _xixi subagent.
#
# On Write to /tmp/xixi-prompt-<8-alnum-id> by agent _xixi: open with O_NOFOLLOW,
# copy to clipboard, unlink. Always exit 0; status via additionalContext.
set -uo pipefail

MAX_BYTES=524288  # 512 KiB
COPY_SCRIPT="${HOME}/.claude/agents/scripts/copy-prompt.sh"
XIXI_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${XIXI_DIR}/common.sh"

input=$(cat)

file_path=""
agent_type=""
if command -v jq >/dev/null 2>&1; then
  file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
  agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null || true)
fi

# Require path shape AND _xixi attribution (audit: other agents must not trigger clipboard).
if ! is_allowed_xixi_path "$file_path"; then
  exit 0
fi
if ! is_xixi_agent "$agent_type"; then
  exit 0
fi

emit_status() {
  local ctx="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg ctx "$ctx" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
      },
      systemMessage: $ctx
    }' 2>/dev/null && return 0
  fi
  printf '%s\n' "$ctx"
}

copy_and_cleanup() {
  local p="$1"
  if command -v python3 >/dev/null 2>&1 && [ -x "$COPY_SCRIPT" ]; then
    python3 - "$p" "$COPY_SCRIPT" "$MAX_BYTES" <<'PY'
import os, sys, subprocess, stat
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
try:
    r = subprocess.run([copy_script], input=data, check=False)
    sys.exit(0 if r.returncode == 0 else 6)
except OSError:
    sys.exit(6)
PY
    return $?
  fi
  # Bash fallback (weaker TOCTOU)
  if [ -L "$p" ]; then return 10; fi
  if [ ! -f "$p" ]; then return 11; fi
  local size
  size=$(wc -c < "$p" | tr -d '[:space:]')
  [[ "$size" =~ ^[0-9]+$ ]] || return 12
  [ "$size" -eq 0 ] && return 13
  [ "$size" -gt "$MAX_BYTES" ] && return 14
  [ -x "$COPY_SCRIPT" ] || return 15
  if "$COPY_SCRIPT" < "$p"; then
    rm -f -- "$p" 2>/dev/null || true
    return 0
  fi
  rm -f -- "$p" 2>/dev/null || true
  return 16
}

rc=0
copy_and_cleanup "$file_path" || rc=$?

case "$rc" in
  0)
    emit_status "[xixi-hook] ✅ refined prompt copied to clipboard. Tell the user exactly: ✅ 改良后的 prompt 已复制到剪贴板 — and do NOT paste the prompt body in chat."
    ;;
  2|10)
    emit_status "[xixi-hook] ⚠️ refused: $file_path is a symlink or open failed (O_NOFOLLOW). Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
    ;;
  3)
    emit_status "[xixi-hook] ⚠️ refused: not a regular file. Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
    ;;
  4|13)
    emit_status "[xixi-hook] ⚠️ refused: empty file. Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
    ;;
  5|14)
    emit_status "[xixi-hook] ⚠️ refused: too large (> ${MAX_BYTES} bytes). Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
    ;;
  11|12)
    emit_status "[xixi-hook] ⚠️ refused: $file_path missing or unreadable. Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
    ;;
  15)
    emit_status "[xixi-hook] ⚠️ clipboard copy failed (copy-prompt.sh missing). Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
    ;;
  *)
    emit_status "[xixi-hook] ⚠️ clipboard copy failed. Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
    ;;
esac
exit 0
