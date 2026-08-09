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
AGENT_CONTRACT_FILE="${AGENT_CONTRACT_FILE:-${HOOKS_DIR}/../tests/fixtures/agent-contract.tsv}"
HOOK_AUDIT_LOG="${HOOK_AUDIT_LOG:-${TMPDIR:-/tmp}/claude-agent-bash-gate.audit.log}"

cmd=""
agent=""

observe_attribution() {
  local observed_agent="${agent:-<absent>}"
  observed_agent="${observed_agent//$'\n'/ }"
  observed_agent="${observed_agent//$'\r'/ }"
  printf '[bash-hook] attribution agent_type=%s\n' "$observed_agent" >&2
}

audit_decision() {
  local rule="$1" decision="$2" logged_agent epoch
  logged_agent="${agent:-<absent>}"
  logged_agent="${logged_agent//$'\n'/ }"
  logged_agent="${logged_agent//$'\r'/ }"
  (
    epoch=$(date +%s 2>/dev/null || printf '0')
    printf '%s agent_type=%s rule=%s decision=%s\n' \
      "$epoch" "$logged_agent" "$rule" "$decision" >> "$HOOK_AUDIT_LOG"
  ) 2>/dev/null || true
}

input=$(cat)

# A direct invocation with no hook payload is a main-session/no-op probe.
if [[ -z "$input" ]]; then
  observe_attribution
  audit_decision "direct-noop" "allow"
  exit 0
fi

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
  # No jq: fail closed if any named agent_type appears in the raw payload.
  if printf '%s' "$input" | grep -qE '"agent_type"[[:space:]]*:[[:space:]]*"[^"[:space:]]+"'; then
    agent=$(printf '%s' "$input" | sed -n 's/.*"agent_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    parse_ok=0
  else
    cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    agent=""
    parse_ok=1
  fi
fi

observe_attribution

block() {
  local reason="$1"
  local rule="${2:-deny}"
  local parsed_rule=""
  if [[ "$rule" == "deny" ]]; then
    parsed_rule="$(printf '%s' "$reason" | sed -n 's/.*(rule:\([^)]*\)).*/\1/p')"
    if [[ -n "$parsed_rule" ]]; then
      rule="$parsed_rule"
    elif [[ "$reason" == *"approval file"* ]]; then
      rule="approval-required"
    fi
  fi
  audit_decision "$rule" "deny"
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
    block "[bash-hook] BLOCKED: jq unavailable — cannot attribute agent_type for Bash gate. Install jq." "parse-no-jq"
  fi
  block "[bash-hook] BLOCKED: cannot parse Bash tool payload (rule:parse)." "parse"
fi

if [[ -z "$agent" ]]; then
  audit_decision "main-session" "allow"
  exit 0
fi

if [[ ! -r "$AGENT_CONTRACT_FILE" ]]; then
  block "[bash-hook] BLOCKED: agent contract unavailable (rule:contract)." "contract-missing"
fi
agent_policy="$(awk -F'|' -v target="$agent" '$1 == target { print $5; exit }' "$AGENT_CONTRACT_FILE" 2>/dev/null || true)"
case "$agent_policy" in
  review_only)
    block "[bash-hook] BLOCKED: agent_type=$agent must not use Bash (rule:review-only)." "review-only"
    ;;
  mutator) ;;
  "")
    block "[bash-hook] BLOCKED: named agent is absent from the fleet contract (rule:unknown-agent)." "unknown-agent"
    ;;
  *)
    block "[bash-hook] BLOCKED: invalid agent policy in fleet contract (rule:contract)." "contract-invalid"
    ;;
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
  local name="$1" f claim age now mtime mode
  f="${APPROVAL_DIR}/${name}"
  if [[ ! -f "$f" ]]; then
    return 1
  fi
  claim="${f}.consuming.$$"
  if ! mv -- "$f" "$claim" 2>/dev/null; then
    return 1
  fi
  mode=$(stat -f %Lp "$claim" 2>/dev/null || stat -c %a "$claim" 2>/dev/null || printf 'unknown')
  if [[ "$mode" != "600" ]]; then
    rm -f -- "$claim" 2>/dev/null || true
    return 1
  fi
  if ! now=$(date +%s 2>/dev/null); then
    rm -f -- "$claim" 2>/dev/null || true
    return 1
  fi
  mtime=$(stat -f %m "$claim" 2>/dev/null || stat -c %Y "$claim" 2>/dev/null || printf '0')
  age=$((now - mtime))
  if [[ "$mtime" -eq 0 || "$age" -lt 0 || "$age" -ge "$APPROVAL_MAX_AGE_SEC" ]]; then
    rm -f -- "$claim" 2>/dev/null || true
    return 1
  fi
  rm -f -- "$claim" 2>/dev/null || true
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
  host="${host%.}"
  printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

host_safe() {
  local host="$1" candidate
  case "$host" in
    localhost|127.0.0.1|::1) return 0 ;;
    *.test|*.local) return 0 ;;
  esac
  [[ -n "${E2E_ALLOWED_HOSTS:-}" ]] || return 1
  local -a allowed_hosts
  IFS=',' read -ra allowed_hosts <<< "${E2E_ALLOWED_HOSTS:-}"
  for candidate in "${allowed_hosts[@]}"; do
    candidate="$(printf '%s' "$candidate" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
    [[ -n "$candidate" && "$candidate" == "$host" ]] && return 0
  done
  return 1
}

validate_config_file() {
  local cfg="$1" config_url config_host
  if [[ ! -f "$cfg" ]]; then
    block "[bash-hook] BLOCKED: Playwright config file not found (rule:prod-guard-config)." "prod-guard-config-missing"
  fi
  while IFS= read -r config_url; do
    [[ -n "$config_url" ]] || continue
    config_host="$(url_host "$config_url")"
    if [[ -z "$config_host" ]] || ! host_safe "$config_host"; then
      block "[bash-hook] BLOCKED: playwright.config baseURL not local/staging (rule:prod-guard-config)." "prod-guard-config"
    fi
  done < <(grep -iE 'baseURL[[:space:]]*:' "$cfg" 2>/dev/null | grep -ioE 'https?://[^[:space:]"'"'"']+' || true)
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
    done < <(printf '%s' "$norm" | grep -ioE 'https?://[^[:space:]"'"'"']+' || true)

    # Validate the effective config path even when --config is present. Literal
    # baseURLs use the same parsed-host policy as BASE_URL and --base-url.
    if printf '%s' "$norm" | grep -qE '^(node_modules/\.bin/playwright|playwright|npx[[:space:]]+--no-install[[:space:]]+playwright)[[:space:]]+test([[:space:]]|$)'; then
      _config_path=""
      if [[ "$norm" =~ (^|[[:space:]])--config=([^[:space:]]+) ]]; then
        _config_path="${BASH_REMATCH[2]}"
      elif [[ "$norm" =~ (^|[[:space:]])--config[[:space:]]+([^[:space:]]+) ]]; then
        _config_path="${BASH_REMATCH[2]}"
      elif printf '%s' "$norm" | grep -qE -- '(^|[[:space:]])--config([[:space:]]|$)'; then
        block "[bash-hook] BLOCKED: --config requires a path (rule:prod-guard-config)." "prod-guard-config-arg"
      fi
      _config_path="${_config_path#\"}"; _config_path="${_config_path%\"}"
      _config_path="${_config_path#\'}"; _config_path="${_config_path%\'}"
      if [[ -n "$_config_path" ]]; then
        validate_config_file "$_config_path"
      elif [[ -z "${BASE_URL:-}" ]] && ! printf '%s' "$norm" | grep -qE -- '--base-url'; then
        for cfg in playwright.config.*; do
          [[ -f "$cfg" ]] || continue
          validate_config_file "$cfg"
        done
      fi
    fi

    # Validate an anchored launcher and complete privileged command before consuming
    # a one-shot approval. Substring mentions never consume or borrow a token.
    if printf '%s' "$norm" | grep -qE 'playwright[[:space:]]+install[[:space:]]+--with-deps'; then
      if ! printf '%s' "$norm" | grep -qE '^(node_modules/\.bin/playwright|playwright|npx[[:space:]]+--no-install[[:space:]]+playwright)[[:space:]]+install[[:space:]]+--with-deps$'; then
        block "[bash-hook] BLOCKED: invalid privileged Playwright install command (rule:approval-command)." "approval-command"
      fi
      if consume_approval "with-deps"; then
        allowed=1
      else
        block "[bash-hook] BLOCKED: playwright install --with-deps needs orchestrator approval file hooks/approvals/with-deps (max ${APPROVAL_MAX_AGE_SEC}s, one-shot)."
      fi
    elif printf '%s' "$norm" | grep -qE -- '(--update-snapshots|(^|[[:space:]])-u([[:space:]]|$))'; then
      if ! printf '%s' "$norm" | grep -qE '^(node_modules/\.bin/playwright|playwright|npx[[:space:]]+--no-install[[:space:]]+playwright)[[:space:]]+test([[:space:]]|$)'; then
        block "[bash-hook] BLOCKED: invalid snapshot command launcher (rule:approval-command)." "approval-command"
      fi
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
  audit_decision "allowlist" "allow"
  exit 0
fi

block "[bash-hook] BLOCKED: command not on allowlist for $agent (rule:allowlist)." "allowlist"
