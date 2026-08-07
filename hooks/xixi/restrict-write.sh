#!/usr/bin/env bash
# restrict-write.sh — PreToolUse gate for the _xixi subagent.
#
# When agent_type is _xixi / xixi, only allow Write to:
#   /tmp/xixi-prompt-<8-alnum-id>
#
# Canonical: ~/.claude/agents/hooks/xixi/ (git). Live registration: settings.json.
#
# Exit: 0 allow · 2 BLOCK
set -uo pipefail

XIXI_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${XIXI_DIR}/common.sh"

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | grep -qE '"agent_type"[[:space:]]*:[[:space:]]*"_?xixi"'; then
    reason="[xixi-hook] BLOCKED: jq unavailable — cannot enforce _xixi write sandbox. Install jq before using _xixi."
    echo "$reason" >&2
    exit 2
  fi
  exit 0
fi

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null || true)

if ! is_xixi_agent "$agent_type"; then
  exit 0
fi

deny() {
  local reason="$1"
  echo "$reason" >&2
  jq -nc --arg reason "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}' 2>/dev/null || true
  exit 2
}

if ! is_allowed_xixi_path "$file_path"; then
  deny "[xixi-hook] BLOCKED: _xixi may only Write to /tmp/xixi-prompt-<8-alnum-id> (exactly under /tmp, no extensions, no ..). Got: ${file_path:-<empty>} (agent_type=${agent_type})"
fi

# Shape OK and not currently a symlink. Refuse non-empty / wrong-type pre-existing.
if [ -L "$file_path" ]; then
  deny "[xixi-hook] BLOCKED: target is a symlink — TOCTOU guard. Pick a new 8-char id."
fi

if [ -e "$file_path" ]; then
  # Allow only an empty regular file left by reserve_xixi_path (same session race harden)
  if [ -f "$file_path" ]; then
    sz=$(wc -c < "$file_path" 2>/dev/null | tr -d '[:space:]')
    if [[ "$sz" == "0" ]]; then
      # Empty regular file: OK for Write to truncate in place (prefer over free path race)
      exit 0
    fi
  fi
  deny "[xixi-hook] BLOCKED: target already exists — refusing to overwrite/follow (TOCTOU guard). Pick a new 8-char id."
fi

# Atomically reserve empty regular file so a concurrent symlink cannot occupy the path
# without replacing our inode (Write typically truncates existing regular file).
if ! reserve_xixi_path "$file_path"; then
  deny "[xixi-hook] BLOCKED: could not exclusively create target (race or exists). Pick a new 8-char id."
fi

exit 0
