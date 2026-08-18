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
  if declare -F hook_emit_post_context >/dev/null 2>&1; then
    hook_emit_post_context "$ctx"
    return 0
  fi
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

copy_and_cleanup() {
  local p="$1"
  if declare -F xixi_copy_and_cleanup >/dev/null 2>&1; then
    xixi_copy_and_cleanup "$p" "$COPY_SCRIPT" "$MAX_BYTES"
    return $?
  fi
  return 15
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
