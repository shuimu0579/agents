#!/usr/bin/env bash
# restrict-write.sh — PreToolUse gate for the _xixi subagent.
#
# When agent_type is _xixi / xixi, only allow Write to:
#   /tmp/xixi-prompt-<8-alnum-id>
#
# Canonical: ~/.claude/agents/hooks/xixi/ (git). Live registration: settings.json.
#
# Exit: 0 allow · 2 BLOCK
set -euo pipefail

XIXI_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
input=$(cat)

deny() {
  local reason="$1"
  if declare -F hook_deny_pre >/dev/null 2>&1; then
    hook_deny_pre "$reason"
  fi
  echo "$reason" >&2
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg reason "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}' \
      2>/dev/null || true
  fi
  exit 2
}

raw_payload_names_xixi() {
  printf '%s' "$input" | grep -qE '"agent_type"[[:space:]]*:[[:space:]]*"_?xixi"'
}

if ! command -v jq >/dev/null 2>&1; then
  if raw_payload_names_xixi; then
    deny "[xixi-hook] BLOCKED: jq unavailable — cannot enforce _xixi write sandbox. Install jq before using _xixi."
  fi
  exit 0
fi

if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  if raw_payload_names_xixi; then
    deny "[xixi-hook] BLOCKED: malformed JSON for _xixi Write; refusing to fail open."
  fi
  exit 0
fi

if [[ ! -r "${XIXI_DIR}/common.sh" ]]; then
  deny "[xixi-hook] BLOCKED: common.sh missing"
fi
# shellcheck source=common.sh
if ! source "${XIXI_DIR}/common.sh"; then
  deny "[xixi-hook] BLOCKED: failed to source common.sh"
fi
for fn in is_xixi_agent is_allowed_xixi_path reserve_xixi_path assert_reserved_xixi_file; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    deny "[xixi-hook] BLOCKED: common.sh missing required helper ${fn}"
  fi
done

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty')

if ! is_xixi_agent "$agent_type"; then
  exit 0
fi

if [[ -z "$file_path" ]]; then
  deny "[xixi-hook] BLOCKED: _xixi Write payload is missing tool_input.file_path."
fi

if ! is_allowed_xixi_path "$file_path"; then
  deny "[xixi-hook] BLOCKED: _xixi may only Write to /tmp/xixi-prompt-<8-alnum-id> (exactly under /tmp, no extensions, no ..). Got: ${file_path:-<empty>} (agent_type=${agent_type})"
fi

# Deny every pre-existing path, including attacker-created empty files and hard links.
if [[ -e "$file_path" || -L "$file_path" ]]; then
  deny "[xixi-hook] BLOCKED: target already exists — refusing every pre-existing path for _xixi. Pick a new 8-char id."
fi

if ! reserve_xixi_path "$file_path"; then
  deny "[xixi-hook] BLOCKED: could not exclusively create target (race or exists). Pick a new 8-char id."
fi

if ! assert_reserved_xixi_file "$file_path"; then
  deny "[xixi-hook] BLOCKED: reserved target failed ownership/link validation; refusing Write."
fi

exit 0
