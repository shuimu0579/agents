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
  printf '%s' "$input" | grep -qE '"(agent_type|subagentType)"[[:space:]]*:[[:space:]]*"_?xixi"'
}

raw_payload_mentions_xixi_path() {
  printf '%s' "$input" | grep -qE '"file_path"[[:space:]]*:[[:space:]]*"/tmp/xixi-prompt-[A-Za-z0-9]{8}"'
}

# Remove the delivered temp file on a failure path, WITHOUT depending on common.sh.
# jq must parse exactly one object whose top-level identity is unambiguously
# _xixi or xixi and whose single tool path (file_path or path) is the sandbox
# file. Nested names, raw text, missing jq, and unparsed payloads do not rm.
# $(...) strips NUL, so a NUL inside any string is refused before the path is used.
discard_xixi_temp() {
  command -v jq >/dev/null 2>&1 || return 0
  local p
  p="$(printf '%s' "$input" | jq -r -s '
    def take: select(type == "string" and length > 0);
    if length != 1 or (.[0] | type) != "object" then empty
    else
      (.[0] as $o
       | if (($o.agent_type != null and ($o.agent_type | type) != "string")
             or ($o.subagentType != null and ($o.subagentType | type) != "string")
             or ([$o | .. | strings | contains("\u0000")] | any))
         then empty
         else
           ([$o.agent_type, $o.subagentType] | map(take) | unique) as $ids
           | (
               (if ($o.tool_input | type) == "object" then [$o.tool_input.file_path, $o.tool_input.path] else [] end)
               + (if ($o.toolInput | type) == "object" then [$o.toolInput.file_path, $o.toolInput.path] else [] end)
               | map(take) | unique
             ) as $paths
           | if ($ids | length) == 1 and ($ids[0] == "_xixi" or $ids[0] == "xixi") and ($paths | length) == 1
             then $paths[0]
             else empty end
         end)
    end
  ' 2>/dev/null || true)"
  case "$p" in
    /tmp/xixi-prompt-[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
    *) return 0 ;;
  esac
  case "$p" in *..*|*$'\n'*|*$'\r'*) return 0 ;; esac
  [ -L "$p" ] && return 0
  [ -f "$p" ] || return 0
  rm -f -- "$p" 2>/dev/null || true
}

emit_clipboard_warning() {
  local detail="$1"
  emit_status "[xixi-hook] ⚠️ ${detail}. Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
}

if [[ ! -r "${XIXI_DIR}/common.sh" ]]; then
  if raw_payload_names_xixi; then
    emit_clipboard_warning "clipboard copy unavailable: common.sh missing"
  fi
  discard_xixi_temp
  exit 0
fi
# shellcheck source=common.sh
if ! source "${XIXI_DIR}/common.sh"; then
  if raw_payload_names_xixi; then
    emit_clipboard_warning "clipboard copy unavailable: failed to source common.sh"
  fi
  discard_xixi_temp
  exit 0
fi
for fn in is_xixi_agent is_allowed_xixi_path; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    if raw_payload_names_xixi; then
      emit_clipboard_warning "clipboard copy unavailable: common.sh helper ${fn} missing"
    fi
    discard_xixi_temp
    exit 0
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  if raw_payload_names_xixi && raw_payload_mentions_xixi_path; then
    emit_clipboard_warning "clipboard copy unavailable: jq missing so _xixi hook attribution could not be verified"
  fi
  discard_xixi_temp
  exit 0
fi

if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  if raw_payload_names_xixi && raw_payload_mentions_xixi_path; then
    emit_clipboard_warning "clipboard copy unavailable: malformed JSON prevented _xixi hook attribution"
  fi
  discard_xixi_temp
  exit 0
fi

# `jq -e .` accepts any truthy JSON, and without -s it accepts the first document
# of concatenated JSON. Require exactly one event object.
if ! printf '%s' "$input" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
  if raw_payload_mentions_xixi_path; then
    emit_clipboard_warning "clipboard copy unavailable: payload is not a JSON object so _xixi hook attribution could not be verified"
  fi
  discard_xixi_temp
  exit 0
fi
# Non-string identity used to fall through take() and look like the main session.
# PostToolUse warns and leaves the temp file; it does not delete on this path.
if ! printf '%s' "$input" | jq -e '
  (.agent_type == null or (.agent_type | type == "string")) and
  (.subagentType == null or (.subagentType | type == "string")) and
  ([.. | strings | contains("\u0000")] | any | not)
' >/dev/null 2>&1; then
  emit_clipboard_warning "clipboard copy unavailable: invalid attribution"
  exit 0
fi

# Index only real objects, and keep jq's exit status off this script's set -e.
# tool_input:true used to abort with exit 5 before toolInput was read.
if printf '%s' "$input" | jq -e '
  def take: select(type == "string" and length > 0);
  def many($xs): ($xs | map(take) | unique | length) > 1;
  many([.agent_type, .subagentType])
  or many(
    (if (.tool_input | type) == "object" then [.tool_input.file_path, .tool_input.path] else [] end)
    + (if (.toolInput | type) == "object" then [.toolInput.file_path, .toolInput.path] else [] end)
  )
' >/dev/null 2>&1; then
  if raw_payload_names_xixi; then
    emit_clipboard_warning "conflicting snake_case and camelCase fields"
  fi
  exit 0
fi

file_path=$(printf '%s' "$input" | jq -r '
  def take: select(type == "string" and length > 0);
  try (
    (
      (if (.tool_input | type) == "object" then [.tool_input.file_path, .tool_input.path] else [] end)
      + (if (.toolInput | type) == "object" then [.toolInput.file_path, .toolInput.path] else [] end)
    ) | map(take) | unique | .[0] // empty
  ) catch empty
' 2>/dev/null || true)
agent_type=$(printf '%s' "$input" | jq -r '
  def take: select(type == "string" and length > 0);
  try ([.agent_type, .subagentType] | map(take) | unique | .[0] // empty) catch empty
' 2>/dev/null || true)

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
  16)
    emit_status "[xixi-hook] ⚠️ refused: python3 unavailable, so the single-descriptor read that guards this copy cannot run (audit #23). Install python3 to restore clipboard delivery. Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
    ;;
  *)
    emit_status "[xixi-hook] ⚠️ clipboard copy failed. Paste the full refined prompt into chat as fallback, then tell the user ⚠️ 剪贴板复制失败，上方为完整 prompt，请手动复制"
    ;;
esac
exit 0
