#!/usr/bin/env bash
# core.sh — Core Hook I/O, Protocol JSON Formatting, and Audit Logging
# Sourced by fleet hooks.
set -euo pipefail

# Print attribution of agent_type to stderr (used by bash gate)
hook_observe_attribution() {
  local agent="${1:-<absent>}"
  agent="${agent//$'\n'/ }"
  agent="${agent//$'\r'/ }"
  printf '[bash-hook] attribution agent_type=%s\n' "$agent" >&2
}

# Log an audit decision: <epoch> agent_type=<agent> rule=<rule> decision=<decision>
hook_audit_log() {
  local log_file="$1" agent="${2:-<absent>}" rule="$3" decision="$4" epoch
  agent="${agent//$'\n'/ }"
  agent="${agent//$'\r'/ }"
  (
    epoch=$(date +%s 2>/dev/null || printf '0')
    printf '%s agent_type=%s rule=%s decision=%s\n' \
      "$epoch" "$agent" "$rule" "$decision" >> "$log_file"
  ) 2>/dev/null || true
}

# Standard PreToolUse deny: print reason to stderr, output JSON on stdout, exit 2
hook_deny_pre() {
  local reason="$1"
  echo "$reason" >&2
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg reason "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}' 2>/dev/null || true
  fi
  exit 2
}

# Standard PostToolUse context emission: output JSON on stdout
hook_emit_post_context() {
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
