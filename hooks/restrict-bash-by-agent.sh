#!/usr/bin/env bash
# restrict-bash-by-agent.sh — PreToolUse Bash gate for mutator agents.
#
# Canonical path (git): ~/.claude/agents/hooks/restrict-bash-by-agent.sh
# Register in settings.json PreToolUse matcher Bash. MUST stay executable (chmod 755).
#
# Exit: 0 allow · 2 BLOCK (stderr to model)
#
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_DIR="${HOOK_LIB_DIR:-${HOOKS_DIR}/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  LIB_DIR="${HOME}/.claude/agents/hooks/lib"
fi

if [[ -f "${LIB_DIR}/core.sh" ]]; then
  source "${LIB_DIR}/core.sh"
fi
if [[ -f "${LIB_DIR}/fs.sh" ]]; then
  source "${LIB_DIR}/fs.sh"
fi
if [[ -f "${LIB_DIR}/security.sh" ]]; then
  source "${LIB_DIR}/security.sh"
fi
if ! declare -F hook_deny_pre >/dev/null 2>&1 || ! declare -F sec_url_extract_host >/dev/null 2>&1; then
  echo "[bash-hook] BLOCKED: required hook libraries missing (rule:lib)." >&2
  exit 2
fi

APPROVAL_DIR="${APPROVAL_DIR:-${HOOKS_DIR}/approvals}"
APPROVAL_MAX_AGE_SEC=300
AGENT_CONTRACT_FILE="${AGENT_CONTRACT_FILE:-${HOOKS_DIR}/../tests/fixtures/agent-contract.tsv}"
HOOK_AUDIT_LOG="${HOOK_AUDIT_LOG:-${TMPDIR:-/tmp}/claude-agent-bash-gate.audit.log}"

cmd=""
agent=""

observe_attribution() {
  hook_observe_attribution "$agent"
}

audit_decision() {
  local rule="$1" decision="$2"
  hook_audit_log "$HOOK_AUDIT_LOG" "$agent" "$rule" "$decision"
}

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
  if declare -F hook_deny_pre >/dev/null 2>&1; then
    hook_deny_pre "$reason"
  fi
  echo "$reason" >&2
  exit 2
}

input=$(cat)

# Direct invocation with no hook payload is a main-session/no-op probe.
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

# Reject multi-line commands on the RAW command, BEFORE normalization.
if [[ "$cmd" == *$'\n'* || "$cmd" == *$'\r'* ]]; then
  block "[bash-hook] BLOCKED: multi-line command (newline/carriage-return) forbidden for $agent (rule:no-newline)." "no-newline"
fi

norm=$(sec_cmd_normalize "$cmd")

if [[ -z "$norm" ]]; then
  block "[bash-hook] BLOCKED: empty command (rule:empty)." "empty"
fi

# Single simple command: reject shell metacharacters / chaining / substitution.
if sec_cmd_has_shell_meta "$norm"; then
  block "[bash-hook] BLOCKED: shell operators/substitutions forbidden for $agent (rule:no-shell-meta). Run one simple command per call." "no-shell-meta"
fi

# Hard denylist (destructive / network / interpreters as code runners / package install)
if sec_cmd_is_destructive "$norm"; then
  block "[bash-hook] BLOCKED: destructive command denied for $agent (rule:deny-destructive)." "deny-destructive"
fi
if sec_cmd_is_network_or_escape "$norm"; then
  block "[bash-hook] BLOCKED: network/shell-escape/interpreter -e denied for $agent (rule:deny-escape)." "deny-escape"
fi
if sec_cmd_is_package_install "$norm"; then
  block "[bash-hook] BLOCKED: package install denied for $agent (rule:deny-install)." "deny-install"
fi

validate_config_url_literal() {
  local config_url="$1" config_host
  [[ -n "$config_url" ]] || return 0
  config_host="$(sec_url_extract_host "$config_url")"
  if [[ -z "$config_host" ]] || ! sec_is_host_safe "$config_host" "${E2E_ALLOWED_HOSTS:-}"; then
    block "[bash-hook] BLOCKED: playwright.config baseURL not local/staging (rule:prod-guard-config)." "prod-guard-config"
  fi
}

# Fail closed when a baseURL key exists but no http(s) host can be statically
# resolved. Same-line literals are checked first; the following line covers
# multiline `baseURL:\n  'https://...'` assignments. Indirect `baseURL: target`
# with the URL on another line cannot be proven safe → block.
validate_config_file() {
  local cfg="$1" config_url url_count=0
  if [[ ! -f "$cfg" ]]; then
    block "[bash-hook] BLOCKED: Playwright config file not found (rule:prod-guard-config)." "prod-guard-config-missing"
  fi
  while IFS= read -r config_url; do
    [[ -n "$config_url" ]] || continue
    url_count=$((url_count + 1))
    validate_config_url_literal "$config_url"
  done < <(grep -iE 'baseURL[[:space:]]*:' "$cfg" 2>/dev/null | grep -ioE 'https?://[^[:space:]"'"'"']+' || true)

  if [[ "$url_count" -eq 0 ]] && grep -qiE 'baseURL[[:space:]]*:' "$cfg" 2>/dev/null; then
    while IFS= read -r config_url; do
      [[ -n "$config_url" ]] || continue
      url_count=$((url_count + 1))
      validate_config_url_literal "$config_url"
    done < <(awk 'tolower($0) ~ /baseurl[ \t]*:/ { want=1; next } want { print; want=0 }' "$cfg" | grep -ioE 'https?://[^[:space:]"'"'"']+' || true)
  fi

  if grep -qiE 'baseURL[[:space:]]*:' "$cfg" 2>/dev/null && [[ "$url_count" -eq 0 ]]; then
    block "[bash-hook] BLOCKED: playwright.config baseURL cannot be resolved statically (rule:prod-guard-config)." "prod-guard-config-unresolved"
  fi
}

allowed=0
case "$agent" in
  e2e-runner)
    # Production-target guard — every candidate authority must be local/test/staging.
    if [[ -n "${BASE_URL:-}" ]]; then
      _host="$(sec_url_extract_host "$BASE_URL")"
      if [[ -z "$_host" ]]; then
        block "[bash-hook] BLOCKED: BASE_URL has no parseable host (rule:prod-guard)." "prod-guard"
      fi
      if ! sec_is_host_safe "$_host" "${E2E_ALLOWED_HOSTS:-}"; then
        block "[bash-hook] BLOCKED: BASE_URL host not on approved staging allowlist (rule:prod-guard)." "prod-guard"
      fi
    fi

    # Validate explicit --base-url args (incl. protocol-relative //host).
    # Flag present with no parseable host (--base-url= / bare --base-url) is a block,
    # not a skip of the config fallback.
    _base_url_flag=0
    _base_url_hosts=0
    if printf '%s' "$norm" | grep -qE -- '(^|[[:space:]])--base-url(=|[[:space:]]|$)'; then
      _base_url_flag=1
    fi
    set -f
    for _b in $(printf '%s' "$norm" | grep -oE -- '--base-url=[^[:space:]]+' | cut -d= -f2- || true) \
              $(printf '%s' "$norm" | grep -oE -- '--base-url[[:space:]]+[^[:space:]]+' | sed 's/^--base-url[[:space:]]*//' || true); do
      [[ -z "$_b" ]] && continue
      _b="${_b#\"}"; _b="${_b%\"}"
      _b="${_b#\'}"; _b="${_b%\'}"
      _bh="$(sec_url_extract_host "$_b")"
      if [[ -z "$_bh" ]]; then
        set +f
        block "[bash-hook] BLOCKED: --base-url has no parseable host (rule:prod-guard)." "prod-guard"
      fi
      if ! sec_is_host_safe "$_bh" "${E2E_ALLOWED_HOSTS:-}"; then
        set +f
        block "[bash-hook] BLOCKED: --base-url host not on approved staging allowlist (rule:prod-guard)." "prod-guard"
      fi
      _base_url_hosts=$((_base_url_hosts + 1))
    done
    set +f
    if [[ "$_base_url_flag" -eq 1 && "$_base_url_hosts" -eq 0 ]]; then
      block "[bash-hook] BLOCKED: --base-url requires a parseable host (rule:prod-guard)." "prod-guard"
    fi

    # Validate inline URLs
    while IFS= read -r _u; do
      [[ -z "$_u" ]] && continue
      _ih="$(sec_url_extract_host "$_u")"
      if [[ -z "$_ih" ]]; then
        block "[bash-hook] BLOCKED: inline URL has no parseable host (rule:prod-guard)." "prod-guard"
      fi
      if ! sec_is_host_safe "$_ih" "${E2E_ALLOWED_HOSTS:-}"; then
        block "[bash-hook] BLOCKED: inline URL host not on approved staging allowlist (rule:prod-guard)." "prod-guard"
      fi
    done < <(printf '%s' "$norm" | grep -ioE 'https?://[^[:space:]"'"'"']+' || true)

    # Validate the effective config path
    if printf '%s' "$norm" | grep -qE '^(node_modules/\.bin/playwright|playwright|npx[[:space:]]+--no-install[[:space:]]+playwright)[[:space:]]+(test|codegen)([[:space:]]|$)'; then
      if [[ -z "${BASE_URL:-}" && "$_base_url_hosts" -eq 0 ]]; then
        block "[bash-hook] BLOCKED: playwright test/codegen requires attested BASE_URL or --base-url (rule:prod-guard)." "prod-guard"
      fi
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
      fi
      # BASE_URL / --base-url are extra candidate authorities, not a skip of cwd config.
      for cfg in playwright.config.*; do
        [[ -f "$cfg" ]] || continue
        [[ -n "$_config_path" && "$cfg" == "$_config_path" ]] && continue
        validate_config_file "$cfg"
      done
    fi

    # Privileged commands requiring one-shot approvals
    if printf '%s' "$norm" | grep -qE 'playwright[[:space:]]+install[[:space:]]+--with-deps'; then
      if ! printf '%s' "$norm" | grep -qE '^(node_modules/\.bin/playwright|playwright|npx[[:space:]]+--no-install[[:space:]]+playwright)[[:space:]]+install[[:space:]]+--with-deps$'; then
        block "[bash-hook] BLOCKED: invalid privileged Playwright install command (rule:approval-command)." "approval-command"
      fi
      if sec_consume_approval "$APPROVAL_DIR" "with-deps" "$APPROVAL_MAX_AGE_SEC"; then
        allowed=1
      else
        block "[bash-hook] BLOCKED: playwright install --with-deps needs orchestrator approval file hooks/approvals/with-deps (max ${APPROVAL_MAX_AGE_SEC}s, one-shot)." "approval-required"
      fi
    elif printf '%s' "$norm" | grep -qE -- '(--update-snapshots|(^|[[:space:]])-u([[:space:]]|$))'; then
      if ! printf '%s' "$norm" | grep -qE '^(node_modules/\.bin/playwright|playwright|npx[[:space:]]+--no-install[[:space:]]+playwright)[[:space:]]+test([[:space:]]|$)'; then
        block "[bash-hook] BLOCKED: invalid snapshot command launcher (rule:approval-command)." "approval-command"
      fi
      if sec_consume_approval "$APPROVAL_DIR" "snapshots" "$APPROVAL_MAX_AGE_SEC"; then
        allowed=1
      else
        block "[bash-hook] BLOCKED: --update-snapshots needs orchestrator approval file hooks/approvals/snapshots (max ${APPROVAL_MAX_AGE_SEC}s, one-shot)." "approval-required"
      fi
    # Safe local Playwright invocations + read-only git/ls/which
    elif printf '%s' "$norm" | grep -qiE \
      '^(node_modules/\.bin/playwright|playwright|npx[[:space:]]+--no-install[[:space:]]+playwright)[[:space:]]+(test|show-report|codegen)([[:space:]]|$)|^git[[:space:]]+(status|diff|log|show)([[:space:]]|$)|^ls([[:space:]]|$)|^which([[:space:]]|$)|^command[[:space:]]+-v([[:space:]]|$)'; then
      local norm_clean
      norm_clean="$(printf '%s' "$norm" | tr -d '"'"'")"
      if printf '%s' "$norm_clean" | grep -qiE '^git[[:space:]]+(diff|show|log)[[:space:]].*--output='; then
        block "[bash-hook] BLOCKED: writable git option --output= denied for $agent (rule:deny-git-output)." "deny-git-output"
      fi
      if printf '%s' "$norm_clean" | grep -qiE 'playwright[[:space:]]+codegen([[:space:]].*)?(--output(=|[[:space:]])|-o([[:space:]]|=))'; then
        block "[bash-hook] BLOCKED: writable playwright codegen option --output/-o denied for $agent (rule:deny-codegen-output)." "deny-codegen-output"
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
