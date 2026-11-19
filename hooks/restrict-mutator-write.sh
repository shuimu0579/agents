#!/usr/bin/env bash
# restrict-mutator-write.sh — PreToolUse Write|Edit self-protection for subagents.
#
# Always deny Write/Edit of hooks/approvals (orchestrator creates those via Bash).
# When agent_type is set, also deny writes to the fleet gate, its tests/fixtures,
# and live Claude settings — a mutator must not rewrite its own constraints.
#
# Canonical: ~/.claude/agents/hooks/restrict-mutator-write.sh
# Register in the host that loads hooks. Claude: settings.json matcher Write|Edit.
# Grok: ~/.grok/hooks/agent-gates.json matcher Write|Edit|write.
# This file existing does not register the hook. MUST stay executable.
#
# Field names: agent_type|subagentType, tool_input|toolInput, file_path|path.
# Neither identity → main session. An attributed write with no path is denied.
# Attributed agents also cannot write ${HOME}/.grok (config, hooks, the whole tree).
# The main session can. Approvals stay denied for everyone.
# A non-empty payload needs jq (rule:parse-no-jq). Newline or CR in the path is
# denied before canonicalization (rule:path-framing); command substitution cannot
# keep a NUL frame around canon_batch's line-oriented records.
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

# One python3 start costs ~70ms and this hook is on the PreToolUse hot path, paid by
# every Write/Edit. Canonicalizing each path separately meant five interpreter starts
# per decision (~350ms measured). canon_batch resolves them all in a single process;
# results come back one per line, in argument order (audit #34).
canon_batch() {
  python3 -c '
import os, sys
for a in sys.argv[1:]:
    try:
        print(os.path.realpath(os.path.expanduser(a)))
    except Exception:
        print("")
' "$@"
}

FLEET_ROOT="$(cd "${HOOKS_DIR}/.." && pwd -P)"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

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

agent=""
file_path=""
cwd=""
# Same policy as the Bash gate: without jq a non-empty event cannot be attributed,
# including an unattributed write of approvals or an ordinary path.
if ! command -v jq >/dev/null 2>&1; then
  block "[write-hook] BLOCKED: jq unavailable — cannot attribute Write/Edit event (rule:parse-no-jq)."
fi
# Slurp so concatenated documents are not accepted as the first object.
if ! printf '%s' "$input" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
  block "[write-hook] BLOCKED: payload must be a JSON object (rule:schema)."
fi
if ! printf '%s' "$input" | jq -e '
  (.agent_type == null or (.agent_type | type == "string")) and
  (.subagentType == null or (.subagentType | type == "string")) and
  ([.. | strings | contains("\u0000")] | any | not)
' >/dev/null 2>&1; then
  block "[write-hook] BLOCKED: invalid attribution or NUL in payload (rule:schema)."
fi
if printf '%s' "$input" | jq -e '
  def take: select(type == "string" and length > 0);
  def many($xs): ($xs | map(take) | unique | length) > 1;
  many([.agent_type, .subagentType])
  or many(
    (if (.tool_input | type) == "object" then [.tool_input.file_path, .tool_input.path] else [] end)
    + (if (.toolInput | type) == "object" then [.toolInput.file_path, .toolInput.path] else [] end)
  )
' >/dev/null 2>&1; then
  block "[write-hook] BLOCKED: conflicting snake_case and camelCase fields (rule:field-conflict)."
fi
agent=$(printf '%s' "$input" | jq -r '
  def take: select(type == "string" and length > 0);
  try ([.agent_type, .subagentType] | map(take) | unique | .[0] // empty) catch empty
' 2>/dev/null || true)
file_path=$(printf '%s' "$input" | jq -r '
  def take: select(type == "string" and length > 0);
  try (
    (
      (if (.tool_input | type) == "object" then [.tool_input.file_path, .tool_input.path] else [] end)
      + (if (.toolInput | type) == "object" then [.toolInput.file_path, .toolInput.path] else [] end)
    ) | map(take) | unique | .[0] // empty
  ) catch empty
' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r 'try (.cwd // empty) catch empty' 2>/dev/null || true)

if [[ -z "$file_path" ]]; then
  if [[ -n "$agent" ]]; then
    block "[write-hook] BLOCKED: attributed Write/Edit payload is missing a path (rule:missing-path)."
  fi
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
# canon_batch prints one path per line. A newline or CR in the target shifts later
# records, and $(...) strips NUL, so a NUL frame cannot repair that. Reject first.
case "$resolved" in
  *$'\n'*|*$'\r'*)
    block "[write-hook] BLOCKED: path contains a newline or carriage return (rule:path-framing)."
    ;;
esac
# Pure-shell lexical normalization: collapses "." and ".." without resolving
# symlinks. canon_batch (python3) is still preferred because it also resolves
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

if command -v python3 >/dev/null 2>&1; then _HAVE_PYTHON3=1; else _HAVE_PYTHON3=0; fi

# Resolve every path this decision can need in ONE interpreter start: the two roots,
# the target itself, and the two live settings files the self-protection list checks.
_CANON_SETTINGS_1="${CLAUDE_HOME}/settings.json"
_CANON_SETTINGS_2="${CLAUDE_HOME}/settings.local.json"
_CANON_GROK="${HOME}/.grok"
_CANON_TARGET=""
if [[ "$_HAVE_PYTHON3" -eq 1 ]]; then
  _canon_out="$(canon_batch \
    "${HOOKS_DIR}/.." \
    "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}" \
    "$resolved" \
    "${CLAUDE_HOME}/settings.json" \
    "${CLAUDE_HOME}/settings.local.json" \
    "${HOME}/.grok" 2>/dev/null || true)"
  if [[ -n "$_canon_out" ]]; then
    IFS=$'\n' read -r -d '' -a _canon_arr < <(printf '%s\0' "$_canon_out") || true
    # Six inputs, six records. A short array is ambiguous, so it must not set
    # _physical or replace the fleet roots.
    if [[ "${#_canon_arr[@]}" -eq 6 ]]; then
      [[ -n "${_canon_arr[0]:-}" ]] && FLEET_ROOT="${_canon_arr[0]}"
      [[ -n "${_canon_arr[1]:-}" ]] && CLAUDE_HOME="${_canon_arr[1]}"
      _CANON_TARGET="${_canon_arr[2]:-}"
      [[ -n "${_canon_arr[3]:-}" ]] && _CANON_SETTINGS_1="${_canon_arr[3]}"
      [[ -n "${_canon_arr[4]:-}" ]] && _CANON_SETTINGS_2="${_canon_arr[4]}"
      [[ -n "${_canon_arr[5]:-}" ]] && _CANON_GROK="${_canon_arr[5]}"
    fi
  fi
fi

_norm_ok=0
_physical=0
if [[ -n "$_CANON_TARGET" ]]; then
  resolved="$_CANON_TARGET"; _norm_ok=1; _physical=1
fi
# Lexical ".." collapse is the symlink bypass. Attributed writes need the physical
# path. Main session still falls back so the unconditional approvals rule works
# on a machine without python3.
if [[ "$_physical" -eq 0 && -n "$agent" ]]; then
  block "[write-hook] BLOCKED: cannot resolve Write/Edit path physically for $agent (rule:realpath)."
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

# uname is cached once. Darwin bash 3.2 has no ${var,,}, so casefold forks `tr`.
# 2026-10-21, bash 3.2.57: 2.3 ms per fork. A miss in is_protected is 1 path
# fold plus 14 path_matches × 2, about 29 forks (tens of ms). The 5s timeout stays.
if [[ "${_IS_DARWIN_CACHED:-}" != "1" ]]; then
  if [[ "$(uname -s)" == Darwin ]]; then _IS_DARWIN=1; else _IS_DARWIN=0; fi
  _IS_DARWIN_CACHED=1
fi

# Case-fold with Bash parameter expansion (4.0+) or `tr` as a fallback for bash 3.2,
# which is what macOS ships as /bin/bash.
casefold() {
  if [[ "$_IS_DARWIN" -ne 1 ]]; then printf '%s' "$1"; return 0; fi
  if [[ "${BASH_VERSINFO[0]:-3}" -ge 4 ]]; then
    printf '%s' "${1,,}"
  else
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
  fi
}

_FLEET_ROOT_CF="$(casefold "$FLEET_ROOT")"

# Darwin APFS is case-insensitive; string compare after realpath is not enough.
path_matches() {
  local p="$1" prefix="$2" pc pr
  pc="$(casefold "$p")"
  pr="$(casefold "$prefix")"
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
  local p_cf
  p_cf="$(casefold "$p")"
  case "$p_cf" in
    */hooks/approvals|*/hooks/approvals/*) return 0 ;;
  esac
  if [[ -n "$agent" ]]; then
    local fleet_root_cf="$_FLEET_ROOT_CF"
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
    # Grok loads config.toml and hooks from this tree. An attributed agent
    # must not rewrite the gate. The main session still can (agent is empty
    # here, so this block is skipped).
    path_matches "$p" "$_CANON_GROK" && return 0
    local settings_real
    for settings_real in "$_CANON_SETTINGS_1" "$_CANON_SETTINGS_2"; do
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
