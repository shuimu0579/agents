#!/usr/bin/env bash
# restrict-bash-by-agent.sh — PreToolUse Bash gate for mutator agents (grill F9 / audit E6 / grill 2026-08-09).
#
# Canonical path (git): ~/.claude/agents/hooks/restrict-bash-by-agent.sh
# Register in settings.json PreToolUse matcher Bash. MUST stay executable (chmod 755).
#
# Exit: 0 allow · 2 BLOCK (stderr to model)
#
# Policy:
#   - review-only agents: always block Bash
#   - mutator (e2e-runner): single simple command (no shell operators), allowlist match
#   - main session (no agent_type): pass through
#   - parse failure with mutator-like payload: fail closed
#   - multi-line commands: fail closed (checked on the RAW command, before normalization)
#   - privileged e2e ops: one-shot approval files under hooks/approvals/ (orchestrator-only)
#   - production-target guard: fail closed on any non-local/test/staging host (parsed authority)
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPROVAL_DIR="${HOOKS_DIR}/approvals"
APPROVAL_MAX_AGE_SEC=300

input=$(cat)

# A direct invocation with no hook payload is a main-session/no-op probe.
if [[ -z "$input" ]]; then
  exit 0
fi

cmd=""
agent=""
parse_ok=0
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || true)
    agent=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null || true)
    parse_ok=1
  else
    parse_ok=0
  fi
else
  # No jq: fail closed if a restricted agent_type appears in the raw payload.
  if printf '%s' "$input" | grep -qE '"agent_type"[[:space:]]*:[[:space:]]*"(e2e-runner|code-reviewer|security-reviewer|architect)"'; then
    parse_ok=0
  else
    cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    agent=""
    parse_ok=1
  fi
fi

# F3-3: opt-in attribution audit. This is deliberately best-effort: logging must
# never alter the policy decision, including when HOME/date/jq or the log path fails.
debug_attribution() {
  [[ "${HOOK_DEBUG:-}" == "1" ]] || return 0
  (
    local epoch tool logged_agent logged_tool logged_cmd log_path
    [[ -n "${HOME:-}" ]] || exit 0
    epoch=$(date +%s 2>/dev/null || printf '0')
    tool=""
    if command -v jq >/dev/null 2>&1; then
      tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
    fi
    logged_agent="${agent//$'\n'/ }"
    logged_agent="${logged_agent//$'\r'/ }"
    logged_tool="${tool//$'\n'/ }"
    logged_tool="${logged_tool//$'\r'/ }"
    logged_cmd="${cmd//$'\n'/ }"
    logged_cmd="${logged_cmd//$'\r'/ }"
    logged_cmd="${logged_cmd:0:80}"
    log_path="${HOME}/.claude/agents/hooks/agent-type.log"
    printf '%s agent_type=%s tool_name=%s command=%s\n' \
      "$epoch" "$logged_agent" "$logged_tool" "$logged_cmd" >> "$log_path"
  ) 2>/dev/null || true
}
debug_attribution

block() {
  local reason="$1"
  # Do not echo untrusted command bodies (may contain secrets) — rule id only.
  echo "$reason" >&2
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg reason "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}' 2>/dev/null || true
  fi
  exit 2
}

# Parse failure while payload names a restricted agent → fail closed.
if [[ "$parse_ok" -eq 0 ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    block "[bash-hook] BLOCKED: jq unavailable — cannot attribute agent_type for Bash gate. Install jq."
  fi
  block "[bash-hook] BLOCKED: cannot parse Bash tool payload (rule:parse)."
fi

case "$agent" in
  code-reviewer|security-reviewer|architect)
    block "[bash-hook] BLOCKED: agent_type=$agent must not use Bash (rule:review-only)."
    ;;
esac

case "$agent" in
  e2e-runner) ;;
  "") exit 0 ;; # main session / unknown non-restricted
  *) exit 0 ;;
esac

# --- Mutators only below ---

# F2-1 (grill 2026-08-09): reject multi-line commands on the RAW command, BEFORE normalization.
# The allowlist would otherwise match the first line and Bash would run every line.
# Applies to mutators only — the main session may run multi-line scripts.
if [[ "$cmd" == *$'\n'* || "$cmd" == *$'\r'* ]]; then
  block "[bash-hook] BLOCKED: multi-line command (newline/carriage-return) forbidden for $agent (rule:no-newline)."
fi

norm=$(printf '%s' "$cmd" | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]\+/ /g')

if [[ -z "$norm" ]]; then
  block "[bash-hook] BLOCKED: empty command (rule:empty)."
fi

# Single simple command: reject shell metacharacters / chaining / substitution.
if printf '%s' "$norm" | grep -qE '[;&|<>`$(){}]|&&|\|\||\$\(|`|\n|\r'; then
  block "[bash-hook] BLOCKED: shell operators/substitutions forbidden for $agent (rule:no-shell-meta). Run one simple command per call."
fi
if printf '%s' "$norm" | grep -qE '\\;|\\\||\\&'; then
  block "[bash-hook] BLOCKED: escaped shell metacharacters forbidden (rule:no-shell-meta)."
fi

# Hard denylist (destructive / network / interpreters as code runners)
if printf '%s' "$norm" | grep -qiE \
  '^(rm[[:space:]]+-rf|git[[:space:]]+push|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+clean[[:space:]]+-fd|chmod[[:space:]]+777|dd[[:space:]]+|mkfs)'; then
  block "[bash-hook] BLOCKED: destructive command denied for $agent (rule:deny-destructive)."
fi
if printf '%s' "$norm" | grep -qiE \
  '(^|[[:space:]])(curl|wget|nc|ncat|fetch)([[:space:]]|$)|/dev/tcp|(^|[[:space:]])(bash|sh)[[:space:]]+-c|(^|[[:space:]])eval[[:space:]]|(^|[[:space:]])(python3?|perl|ruby)[[:space:]]+-e|(^|[[:space:]])node[[:space:]]+-e'; then
  block "[bash-hook] BLOCKED: network/shell-escape/interpreter -e denied for $agent (rule:deny-escape)."
fi
if printf '%s' "$norm" | grep -qiE \
  '(^|[[:space:]])(npm|yarn|pnpm|bun)[[:space:]]+(install|add|i)([[:space:]]|$)'; then
  block "[bash-hook] BLOCKED: package install denied for $agent (rule:deny-install)."
fi

# One-shot approval files (orchestrator/main session creates; agent cannot forge —
# settings.json PreToolUse Write|Edit blocks writes under hooks/approvals/).
consume_approval() {
  # $1 = token name e.g. with-deps | snapshots
  local name="$1" f age now
  f="${APPROVAL_DIR}/${name}"
  if [[ ! -f "$f" ]]; then
    return 1
  fi
  now=$(date +%s)
  local mtime
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  age=$((now - mtime))
  if [[ "$age" -gt "$APPROVAL_MAX_AGE_SEC" ]]; then
    rm -f -- "$f" 2>/dev/null || true
    return 1
  fi
  rm -f -- "$f" 2>/dev/null || true
  return 0
}

# F2-3: parse a URL authority into its exact host. Handles scheme, protocol-relative //,
# userinfo, host:port, and bracketed IPv6. Empty on a malformed bracketed authority.
url_host() {
  local u="${1}" authority host
  u="${u#*://}"              # strip scheme+:// if present
  u="${u#//}"                # strip protocol-relative //
  authority="${u%%[/?#]*}"   # isolate authority from path/query/fragment
  authority="${authority##*@}" # strip userinfo through the final @

  if [[ "$authority" == \[* ]]; then
    if [[ "$authority" =~ ^\[([^]]+)\](:[0-9]+)?$ ]]; then
      host="${BASH_REMATCH[1]}"
    else
      host=""
    fi
  elif [[ "$authority" =~ ^([^:]+):[0-9]+$ ]]; then
    host="${BASH_REMATCH[1]}"
  else
    host="$authority"
  fi
  printf '%s' "$host"
}

host_safe() {
  case "$1" in
    localhost|127.0.0.1|::1) return 0 ;;
    *.test|*.local|*.staging) return 0 ;;
    *) return 1 ;;
  esac
}

allowed=0
case "$agent" in
  e2e-runner)
    # F2-3: production-target guard — every candidate authority must be local/test/staging.
    if [[ -n "${BASE_URL:-}" ]]; then
      _host="$(url_host "$BASE_URL")"
      if [[ -z "$_host" ]]; then
        block "[bash-hook] BLOCKED: BASE_URL has no parseable host (rule:prod-guard)."
      fi
      if ! host_safe "$_host"; then
        block "[bash-hook] BLOCKED: BASE_URL host not on approved staging allowlist (rule:prod-guard)."
      fi
    fi
    # Validate explicit --base-url args (incl. protocol-relative //host), which the
    # scheme-scoped inline-URL grep below would otherwise miss.
    for _b in $(printf '%s' "$norm" | grep -oE -- '--base-url=[^[:space:]]+' | cut -d= -f2- || true) \
              $(printf '%s' "$norm" | grep -oE -- '--base-url[[:space:]]+[^[:space:]]+' | sed 's/^--base-url[[:space:]]*//' || true); do
      [[ -z "$_b" ]] && continue
      _bh="$(url_host "$_b")"
      if [[ -z "$_bh" ]]; then
        block "[bash-hook] BLOCKED: --base-url has no parseable host (rule:prod-guard)."
      fi
      if ! host_safe "$_bh"; then
        block "[bash-hook] BLOCKED: --base-url host not on approved staging allowlist (rule:prod-guard)."
      fi
    done
    while IFS= read -r _u; do
      [[ -z "$_u" ]] && continue
      _ih="$(url_host "$_u")"
      if [[ -z "$_ih" ]]; then
        block "[bash-hook] BLOCKED: inline URL has no parseable host (rule:prod-guard)."
      fi
      if ! host_safe "$_ih"; then
        block "[bash-hook] BLOCKED: inline URL host not on approved staging allowlist (rule:prod-guard)."
      fi
    done < <(printf '%s' "$norm" | grep -oE 'https?://[^[:space:]"'"'"']+' || true)

    # Best-effort config-embed mitigation: `playwright test` with no explicit --base-url / BASE_URL
    # → validate any baseURL literal found in playwright.config.* in the tool's cwd.
    if printf '%s' "$norm" | grep -qE '(^|[[:space:]])playwright[[:space:]]+test' \
       && ! printf '%s' "$norm" | grep -qE -- '--base-url|--config' \
       && [[ -z "${BASE_URL:-}" ]]; then
      for cfg in playwright.config.*; do
        [[ -f "$cfg" ]] || continue
        _bad="$(grep -oE 'https?://[^"'"'"' ]+' "$cfg" 2>/dev/null | grep -vE 'localhost|127\.0\.0\.1|\[::1\]|\.test|\.local|\.staging' | head -1 || true)"
        if [[ -n "$_bad" ]]; then
          block "[bash-hook] BLOCKED: playwright.config baseURL not local/staging (rule:prod-guard-config)."
        fi
      done
    fi

    # One-shot approvals — scoped to the privileged command forms only (no broad -u borrow).
    if printf '%s' "$norm" | grep -qE '(^|[[:space:]])playwright[[:space:]]+install[[:space:]]+--with-deps'; then
      if consume_approval "with-deps"; then
        allowed=1
      else
        block "[bash-hook] BLOCKED: playwright install --with-deps needs orchestrator approval file hooks/approvals/with-deps (max ${APPROVAL_MAX_AGE_SEC}s, one-shot)."
      fi
    elif printf '%s' "$norm" | grep -qE '(^|[[:space:]])playwright[[:space:]]+test' \
       && printf '%s' "$norm" | grep -qE -- '(--update-snapshots|[[:space:]]-u([[:space:]]|$))'; then
      if consume_approval "snapshots"; then
        allowed=1
      else
        block "[bash-hook] BLOCKED: --update-snapshots needs orchestrator approval file hooks/approvals/snapshots (max ${APPROVAL_MAX_AGE_SEC}s, one-shot)."
      fi
    # F2-2: allowlist — safe local Playwright invocations + read-only git/ls/which. No bare
    # `npx playwright` (auto-installs), no npm/yarn wrappers (arbitrary scripts), no cat.
    elif printf '%s' "$norm" | grep -qiE \
      '^(node_modules/\.bin/playwright|playwright|npx[[:space:]]+--no-install[[:space:]]+playwright)[[:space:]]+(test|show-report|codegen)([[:space:]]|$)|^git[[:space:]]+(status|diff|log|show)([[:space:]]|$)|^ls([[:space:]]|$)|^which([[:space:]]|$)|^command[[:space:]]+-v([[:space:]]|$)' ; then
      if printf '%s' "$norm" | grep -qiE '^git[[:space:]]+(diff|show|log)[[:space:]].*--output='; then
        block "[bash-hook] BLOCKED: writable git option --output= denied for $agent (rule:deny-git-output)."
      fi
      allowed=1
    fi
    ;;
esac

if [[ "$allowed" -eq 1 ]]; then
  exit 0
fi

block "[bash-hook] BLOCKED: command not on allowlist for $agent (rule:allowlist)."
