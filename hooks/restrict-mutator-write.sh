#!/usr/bin/env bash
# restrict-mutator-write.sh — PreToolUse Write|Edit self-protection for subagents.
#
# Always deny Write/Edit of hooks/approvals (orchestrator creates those via Bash).
# When agent_type is set, also deny writes to the fleet gate, its tests/fixtures,
# and live Claude settings — a mutator must not rewrite its own constraints.
#
# Canonical: ~/.claude/agents/hooks/restrict-mutator-write.sh
# Register in settings.json PreToolUse matcher Write|Edit. MUST stay executable.
#
# Exit: 0 allow · 2 BLOCK
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_DIR="${HOOK_LIB_DIR:-${HOOKS_DIR}/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  LIB_DIR="${HOME}/.claude/agents/hooks/lib"
fi
if [[ -f "${LIB_DIR}/core.sh" ]]; then
  source "${LIB_DIR}/core.sh"
fi

canon_path() {
  python3 -c 'import os,sys; print(os.path.realpath(os.path.normpath(os.path.expanduser(sys.argv[1]))))' "$1"
}

FLEET_ROOT="$(cd "${HOOKS_DIR}/.." && pwd -P)"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
if command -v python3 >/dev/null 2>&1; then
  _fr="$(canon_path "${HOOKS_DIR}/..")" && [[ -n "$_fr" ]] && FLEET_ROOT="$_fr"
  _ch="$(canon_path "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")" && [[ -n "$_ch" ]] && CLAUDE_HOME="$_ch"
fi

block() {
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

input=$(cat)

if [[ -z "$input" ]]; then
  exit 0
fi

parse_ok=0
agent=""
file_path=""
cwd=""
if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    block "[write-hook] BLOCKED: payload must be a JSON object (rule:schema)."
  fi
  agent=$(printf '%s' "$input" | jq -r 'try (.agent_type // empty) catch empty' 2>/dev/null || true)
  file_path=$(printf '%s' "$input" | jq -r 'try (.tool_input.file_path // .tool_input.path // empty) catch empty' 2>/dev/null || true)
  cwd=$(printf '%s' "$input" | jq -r 'try (.cwd // empty) catch empty' 2>/dev/null || true)
  parse_ok=1
else
  if printf '%s' "$input" | grep -qE '"agent_type"[[:space:]]*:[[:space:]]*"[^"[:space:]]+"'; then
    block "[write-hook] BLOCKED: jq unavailable — cannot attribute agent_type for Write/Edit gate. Install jq."
  fi
  exit 0
fi

if [[ "$parse_ok" -eq 0 ]]; then
  if printf '%s' "$input" | grep -qE '"agent_type"[[:space:]]*:[[:space:]]*"[^"[:space:]]+"'; then
    block "[write-hook] BLOCKED: cannot parse Write/Edit payload (rule:parse)."
  fi
  exit 0
fi

if [[ -z "$file_path" ]]; then
  exit 0
fi

[[ -z "$cwd" ]] && cwd="$PWD"

resolved="$file_path"
if [[ "$resolved" == ~* ]]; then
  resolved="${resolved/#\~/$HOME}"
fi
if [[ "$resolved" != /* ]]; then
  resolved="${cwd%/}/${resolved}"
fi
# Pure-shell lexical normalization: collapses "." and ".." without resolving
# symlinks. canon_path (python3) is still preferred because it also resolves
# symlinks, but the approvals rule is documented as unconditional, so it must not
# depend on python3 being installed. Without this, a path such as
# .../hooks/lib/../approvals/with-deps never matches the approvals glob.
lexical_norm() {
  local p="$1" seg out=() oldifs="$IFS"
  IFS='/' read -r -a _segs <<< "$p"
  IFS="$oldifs"
  for seg in ${_segs[@]+"${_segs[@]}"}; do
    case "$seg" in
      ''|.) continue ;;
      ..)   [[ ${#out[@]} -gt 0 ]] && unset "out[$(( ${#out[@]} - 1 ))]" ;;
      *)    out+=("$seg") ;;
    esac
  done
  if [[ ${#out[@]} -eq 0 ]]; then printf '/'; else printf '/%s' "${out[@]}"; fi
}

_norm_ok=0
if command -v python3 >/dev/null 2>&1; then
  _canon="$(canon_path "$resolved")"
  _canon_rc=$?
  if [[ "$_canon_rc" -eq 0 && -n "$_canon" ]]; then
    resolved="$_canon"; _norm_ok=1
  fi
fi
if [[ "$_norm_ok" -eq 0 ]]; then
  _lex="$(lexical_norm "$resolved" 2>/dev/null || true)"
  if [[ -n "$_lex" && "$_lex" == /* ]]; then
    resolved="$_lex"; _norm_ok=1
  fi
fi
# Fail closed: an attributed write whose path cannot be normalized at all is denied,
# and so is ANY write (main session included) once normalization has failed, because
# the approvals rule below is unconditional and cannot be evaluated on a raw path.
if [[ "$_norm_ok" -eq 0 ]]; then
  if [[ -n "$agent" ]]; then
    block "[write-hook] BLOCKED: cannot normalize Write/Edit path for $agent (rule:self-protect)."
  fi
  block "[write-hook] BLOCKED: cannot normalize path; approval protection cannot be evaluated (rule:approvals)."
fi

# Darwin APFS is case-insensitive; string compare after realpath is not enough.
path_matches() {
  local p="$1" prefix="$2" pc pr
  if [[ "$(uname -s)" == Darwin ]]; then
    pc=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
    pr=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')
  else
    pc="$p"
    pr="$prefix"
  fi
  [[ "$pc" == "$pr" || "$pc" == "$pr"/* ]]
}

is_protected() {
  local p="$1"
  local hooks_prefix="${FLEET_ROOT}/hooks"
  local tests_prefix="${FLEET_ROOT}/tests"
  local scripts_prefix="${FLEET_ROOT}/scripts"
  case "$p" in
    */hooks/approvals|*/hooks/approvals/*) return 0 ;;
  esac
  # Case-folded copy for the glob (macOS: Hooks/ vs hooks/).
  local p_cf="$p"
  [[ "$(uname -s)" == Darwin ]] && p_cf=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
  case "$p_cf" in
    */hooks/approvals|*/hooks/approvals/*) return 0 ;;
  esac
  if [[ -n "$agent" ]]; then
    local fleet_root_cf="$FLEET_ROOT"
    [[ "$(uname -s)" == Darwin ]] && fleet_root_cf=$(printf '%s' "$FLEET_ROOT" | tr '[:upper:]' '[:lower:]')
    case "$p_cf" in
      "${fleet_root_cf}/"*.md) return 0 ;;
    esac
    path_matches "$p" "$hooks_prefix" && return 0
    path_matches "$p" "$tests_prefix" && return 0
    path_matches "$p" "$scripts_prefix" && return 0
    path_matches "$p" "${CLAUDE_HOME}/hooks" && return 0
    path_matches "$p" "${CLAUDE_HOME}/scripts" && return 0
    path_matches "$p" "${CLAUDE_HOME}/settings.json" && return 0
    path_matches "$p" "${CLAUDE_HOME}/settings.local.json" && return 0
    # The live policy registry decides what agents may do; an agent writing it
    # rewrites its own limits (audit #7).
    path_matches "$p" "${CLAUDE_HOME}/rules" && return 0
    # Project-local settings are loaded the same way the CLAUDE_HOME copies are.
    path_matches "$p" "${FLEET_ROOT}/.claude/settings.json" && return 0
    path_matches "$p" "${FLEET_ROOT}/.claude/settings.local.json" && return 0
    # .git holds executable configuration: config can name diff/textconv helpers and
    # .git/hooks runs on ordinary git operations.
    path_matches "$p" "${FLEET_ROOT}/.git" && return 0
    local settings_real
    for settings_real in "${CLAUDE_HOME}/settings.json" "${CLAUDE_HOME}/settings.local.json"; do
      if command -v python3 >/dev/null 2>&1; then
        settings_real="$(canon_path "$settings_real" 2>/dev/null || printf '%s' "$settings_real")"
      fi
      path_matches "$p" "$settings_real" && return 0
    done
  fi
  return 1
}

if is_protected "$resolved"; then
  if [[ -n "$agent" ]]; then
    block "[write-hook] BLOCKED: agent_type=$agent must not Write/Edit fleet hooks, tests, approvals, or live settings (rule:self-protect)."
  fi
  block "[write-hook] BLOCKED: approval files are orchestrator-only (rule:approvals)."
fi

exit 0
