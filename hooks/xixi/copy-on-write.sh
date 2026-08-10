#!/usr/bin/env bash
# copy-on-write.sh — PostToolUse hook for the _xixi subagent.
#
# On Write to /tmp/xixi-prompt-<8-alnum-id> by agent _xixi: open with O_NOFOLLOW,
# copy to clipboard, unlink. Always exit 0; status via additionalContext.
set -euo pipefail

MAX_BYTES=524288  # 512 KiB
COPY_SCRIPT="${COPY_SCRIPT:-$HOME/.claude/agents/scripts/copy-prompt.sh}"
XIXI_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
input=$(cat)

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

raw_payload_names_xixi() {
  printf '%s' "$input" | grep -qE '"agent_type"[[:space:]]*:[[:space:]]*"_?xixi"'
}

raw_payload_mentions_xixi_path() {
  printf '%s' "$input" | grep -qE '"file_path"[[:space:]]*:[[:space:]]*"/tmp/xixi-prompt-[A-Za-z0-9]{8}"'
}

emit_clipboard_warning() {
  local detail="$1"
  emit_status "[xixi-hook] ⚠️ ${detail}. Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
}

if [[ ! -r "${XIXI_DIR}/common.sh" ]]; then
  if raw_payload_names_xixi; then
    emit_clipboard_warning "clipboard copy unavailable: common.sh missing"
  fi
  exit 0
fi
# shellcheck source=common.sh
if ! source "${XIXI_DIR}/common.sh"; then
  if raw_payload_names_xixi; then
    emit_clipboard_warning "clipboard copy unavailable: failed to source common.sh"
  fi
  exit 0
fi
for fn in is_xixi_agent is_allowed_xixi_path; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    if raw_payload_names_xixi; then
      emit_clipboard_warning "clipboard copy unavailable: common.sh helper ${fn} missing"
    fi
    exit 0
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  if raw_payload_names_xixi && raw_payload_mentions_xixi_path; then
    emit_clipboard_warning "clipboard copy unavailable: jq missing so _xixi hook attribution could not be verified"
  fi
  exit 0
fi

if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  if raw_payload_names_xixi && raw_payload_mentions_xixi_path; then
    emit_clipboard_warning "clipboard copy unavailable: malformed JSON prevented _xixi hook attribution"
  fi
  exit 0
fi

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty')

# Require path shape AND _xixi attribution.
if ! is_allowed_xixi_path "$file_path"; then
  exit 0
fi
if ! is_xixi_agent "$agent_type"; then
  exit 0
fi

portable_nlink() {
  local p="$1"
  local out
  if out=$(stat -f '%l' "$p" 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  if out=$(stat -c '%h' "$p" 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

copy_and_cleanup() {
  local p="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$p" "$COPY_SCRIPT" "$MAX_BYTES" <<'PY'
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

  if [ -L "$p" ]; then
    return 10
  fi
  if [ ! -f "$p" ]; then
    return 11
  fi

  local nlink size
  nlink=$(portable_nlink "$p") || return 17
  [[ "$nlink" =~ ^[0-9]+$ ]] || return 17
  [ "$nlink" -eq 1 ] || { rm -f -- "$p" 2>/dev/null || true; return 18; }

  size=$(wc -c < "$p" | tr -d '[:space:]')
  [[ "$size" =~ ^[0-9]+$ ]] || return 12
  [ "$size" -eq 0 ] && { rm -f -- "$p" 2>/dev/null || true; return 13; }
  [ "$size" -gt "$MAX_BYTES" ] && { rm -f -- "$p" 2>/dev/null || true; return 14; }
  [ -x "$COPY_SCRIPT" ] || { rm -f -- "$p" 2>/dev/null || true; return 15; }

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
  7|18)
    emit_status "[xixi-hook] ⚠️ refused: multi-link file. Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
    ;;
  11|12|17)
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
