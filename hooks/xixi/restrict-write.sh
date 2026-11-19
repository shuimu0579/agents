#!/usr/bin/env bash
# restrict-write.sh — PreToolUse gate for the _xixi subagent.
#
# When agent_type or subagentType is _xixi / xixi, only allow Write to:
#   /tmp/xixi-prompt-<8-alnum-id>
#
# Canonical: ~/.claude/agents/hooks/xixi/ (git).
# Registration is required and is not implied by this file.
# Claude loads ~/.claude/settings.json. Grok loads ~/.grok/hooks/agent-gates.json.
# hooks.json is a non-loaded mirror.
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
  printf '%s' "$input" | grep -qE '"(agent_type|subagentType)"[[:space:]]*:[[:space:]]*"_?xixi"'
}

if ! command -v jq >/dev/null 2>&1; then
  if raw_payload_names_xixi; then
    deny "[xixi-hook] BLOCKED: jq unavailable — cannot enforce _xixi write sandbox. Install jq before using _xixi."
  fi
  exit 0
fi

# Direct invocation with no hook payload is a main-session/no-op probe, matching
# restrict-bash-by-agent.sh. A NON-EMPTY payload that is not one event object is a
# denial: jq without -s reads the first document of concatenated JSON.
if [[ -n "$input" ]] && ! printf '%s' "$input" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
  deny "[xixi-hook] BLOCKED: payload must be a JSON object (rule:schema)."
fi
# take() drops non-strings, so agent_type:17 used to look like the main session.
if [[ -n "$input" ]] && ! printf '%s' "$input" | jq -e '
  (.agent_type == null or (.agent_type | type == "string")) and
  (.subagentType == null or (.subagentType | type == "string")) and
  ([.. | strings | contains("\u0000")] | any | not)
' >/dev/null 2>&1; then
  deny "[xixi-hook] BLOCKED: invalid attribution or NUL in payload (rule:schema)."
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

if printf '%s' "$input" | jq -e '
  def take: select(type == "string" and length > 0);
  def many($xs): ($xs | map(take) | unique | length) > 1;
  many([.agent_type, .subagentType])
  or many(
    (if (.tool_input | type) == "object" then [.tool_input.file_path, .tool_input.path] else [] end)
    + (if (.toolInput | type) == "object" then [.toolInput.file_path, .toolInput.path] else [] end)
  )
' >/dev/null 2>&1; then
  deny "[xixi-hook] BLOCKED: conflicting snake_case and camelCase fields (rule:field-conflict)."
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

# Deliberately kept despite overlapping reserve_xixi_path (audit #49). The two calls
# are adjacent, so this is a post-condition assertion rather than a race check — but it
# costs one interpreter start on a path taken only for _xixi Writes, and dropping a
# validation from a write sandbox to save that is a bad trade. Not hot-path code.
if ! assert_reserved_xixi_file "$file_path"; then
  deny "[xixi-hook] BLOCKED: reserved target failed ownership/link validation; refusing Write."
fi

exit 0
