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
# The repository an approval is bound to (audit #21). Derived from the hook's own
# location, so it names the fleet this gate belongs to rather than whatever tree the
# command happens to be run from.
FLEET_ROOT_FOR_APPROVAL="$(cd "${HOOKS_DIR}/.." && pwd -P)"
APPROVAL_MAX_AGE_SEC=300
AGENT_CONTRACT_FILE="${AGENT_CONTRACT_FILE:-${HOOKS_DIR}/../tests/fixtures/agent-contract.tsv}"
HOOK_AUDIT_LOG="${HOOK_AUDIT_LOG:-${TMPDIR:-/tmp}/claude-agent-bash-gate.audit.log}"

cmd=""
agent=""
session_id=""

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

input=$(cat; printf '.')
input="${input%.}"

# Direct invocation with no hook payload is a main-session/no-op probe.
if [[ -z "$input" ]]; then
  observe_attribution
  audit_decision "direct-noop" "allow"
  exit 0
fi

# A non-empty event requires the JSON parser, even when attribution is absent.
# Slurp also rejects concatenated JSON documents rather than trusting the last one.
if ! command -v jq >/dev/null 2>&1; then
  block "[bash-hook] BLOCKED: jq unavailable — cannot attribute Bash event (rule:parse-no-jq)." "parse-no-jq"
fi
if ! printf '%s' "$input" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
  block "[bash-hook] BLOCKED: payload must be one JSON object (rule:schema)." "schema"
fi
if ! printf '%s' "$input" | jq -e '
  (.agent_type == null or (.agent_type | type == "string")) and
  ([.. | strings | contains("\u0000")] | any | not)
' >/dev/null 2>&1; then
  block "[bash-hook] BLOCKED: invalid attribution or NUL in payload (rule:schema)." "schema"
fi
# The sentinel preserves trailing newlines so command substitution cannot hide
# a multiline command or turn a newline-only agent name into the main session.
cmd=$(printf '%s' "$input" | jq -r 'try (.tool_input.command // .tool_input.cmd // empty | select(type == "string")) catch empty' 2>/dev/null || true; printf '.')
cmd="${cmd%.}"; cmd="${cmd%$'\n'}"
agent=$(printf '%s' "$input" | jq -r 'try (.agent_type // empty) catch empty' 2>/dev/null || true; printf '.')
agent="${agent%.}"; agent="${agent%$'\n'}"
session_id=$(printf '%s' "$input" | jq -r 'try (.session_id // empty | select(type == "string")) catch empty' 2>/dev/null || true; printf '.')
session_id="${session_id%.}"; session_id="${session_id%$'\n'}"
observe_attribution

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

# Bash authority is derived from the agent's DECLARED TOOL SET (contract column 2),
# not from the write-semantics flag in column 5. The two columns are maintained by
# hand and can disagree; deriving from the tools column removes that drift surface,
# and lets an agent keep Write/Edit while losing execution (ADR 0002).
# Fail closed: an unreadable, empty, or Bash-less tool set denies Bash.
agent_tools="$(awk -F'|' -v target="$agent" '$1 == target { print $2; exit }' "$AGENT_CONTRACT_FILE" 2>/dev/null || true)"
if [[ -z "$agent_tools" ]]; then
  block "[bash-hook] BLOCKED: agent_type=$agent declares no tool set in the fleet contract (rule:no-tools)." "no-tools"
fi
if ! printf '%s' "$agent_tools" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -qx 'Bash'; then
  block "[bash-hook] BLOCKED: agent_type=$agent does not declare the Bash tool (rule:no-bash-tool)." "no-bash-tool"
fi

# --- Mutators only below ---

# Tokenize once. Every command policy below consumes SEC_ARGV, not cmd.
if ! sec_cmd_tokenize "$cmd"; then
  block "[bash-hook] BLOCKED: empty, ambiguous, or unsupported shell command (rule:no-shell-meta)." "no-shell-meta"
fi
if sec_cmd_is_destructive "${SEC_ARGV[@]}"; then
  block "[bash-hook] BLOCKED: destructive command denied (rule:deny-destructive)." "deny-destructive"
fi
if sec_cmd_is_network_or_escape "${SEC_ARGV[@]}"; then
  block "[bash-hook] BLOCKED: network/shell-escape/interpreter denied (rule:deny-escape)." "deny-escape"
fi
if sec_cmd_is_package_install "${SEC_ARGV[@]}"; then
  block "[bash-hook] BLOCKED: package install denied (rule:deny-install)." "deny-install"
fi

validate_url() {
  local url="$1" rule="${2:-prod-guard}" host
  host="$(sec_url_extract_host "$url")"
  if [[ -z "$url" || -z "$host" ]] || ! sec_is_host_safe "$host" "${E2E_ALLOWED_HOSTS:-}"; then
    block "[bash-hook] BLOCKED: URL host not local or on staging allowlist (rule:$rule)." "$rule"
  fi
}

validate_config_file() {
  local cfg="$1" urls config_url
  [[ -f "$cfg" ]] || block "[bash-hook] BLOCKED: Playwright config file not found (rule:prod-guard-config)." "prod-guard-config-missing"
  # Capture the parser status directly; process substitution would lose failures.
  if ! urls=$(sec_config_base_urls "$cfg" 2>/dev/null); then
    block "[bash-hook] BLOCKED: playwright.config baseURL cannot be resolved statically (rule:prod-guard-config)." "prod-guard-config-unresolved"
  fi
  while IFS= read -r config_url; do
    [[ -n "$config_url" ]] || continue
    validate_url "$config_url" "prod-guard-config"
  done <<< "$urls"
}

# Option values are read from the same argv array, preserving spaces in paths.
# The option matcher has already set SEC_OPT_ATTACHED and SEC_OPT_VALUE.
option_value() {
  if [[ "$SEC_OPT_ATTACHED" -eq 1 ]]; then
    option_value_result="$SEC_OPT_VALUE"
  else
    i=$((i + 1))
    option_value_result="${SEC_ARGV[i]:-}"
  fi
  if [[ -z "$option_value_result" || "$option_value_result" == -* ]]; then
    block "[bash-hook] BLOCKED: option requires a non-empty value (rule:option-value)." "option-value"
  fi
}

allowed=0
case "$agent" in
  e2e-runner)
    launcher="${SEC_ARGV[0]}"
    subcommand="${SEC_ARGV[1]:-}"
    arg_start=2
    case "$launcher" in
      playwright|node_modules/.bin/playwright) launcher=playwright ;;
      npx)
        if [[ "${SEC_ARGV[1]:-}" == --no-install && "${SEC_ARGV[2]:-}" == playwright ]]; then
          launcher=playwright; subcommand="${SEC_ARGV[3]:-}"; arg_start=4
        fi
        ;;
    esac
    # Exact argv launcher/subcommand matching, before any token is consumed.
    case "$launcher" in
      playwright)
        case "$subcommand" in
          test|show-report|codegen) allowed=1 ;;
          install)
            if [[ ${#SEC_ARGV[@]} -eq $((arg_start + 1)) && "${SEC_ARGV[arg_start]}" == --with-deps ]]; then
              allowed=1
            fi
            ;;
        esac
        ;;
      git) case "$subcommand" in status|diff|log|show) allowed=1 ;; esac ;;
      ls|which) allowed=1; arg_start=1 ;;
      command) [[ "$subcommand" == -v ]] && allowed=1 ;;
    esac
    [[ "$allowed" -eq 1 ]] || block "[bash-hook] BLOCKED: command not on allowlist for $agent (rule:allowlist)." "allowlist"

    snapshot=0
    base_url_hosts=0
    config_paths=()
    # Inspect all argv words for denied/privileged options, even after --. This
    # deliberately cannot let an approval be borrowed by another command family.
    for arg in "${SEC_ARGV[@]}"; do
      if sec_arg_option "$arg" --update-snapshots || [[ "$arg" == -u ]]; then
        snapshot=1
      elif [[ "$launcher" == playwright && "$subcommand" == test ]] && sec_arg_option "$arg" --update-snapshots -u; then
        snapshot=1
      fi
      if [[ "$launcher" == git ]] && sec_arg_option "$arg" --output; then
        block "[bash-hook] BLOCKED: writable git option --output denied (rule:deny-git-output)." "deny-git-output"
      fi
      if [[ "$launcher" == playwright && "$subcommand" == codegen ]]; then
        if sec_arg_option "$arg" --output -o || sec_arg_option "$arg" --save-har || sec_arg_option "$arg" --save-storage; then
          block "[bash-hook] BLOCKED: writable codegen option denied (rule:deny-codegen-output)." "deny-codegen-output"
        fi
      fi
      # URLs may be positionals or attached option values; inspect the argv word
      # itself rather than losing word boundaries through a command re-join.
      url_candidate="$arg"
      [[ "$url_candidate" == --*=* ]] && url_candidate="${url_candidate#*=}"
      case "$url_candidate" in
        [Hh][Tt][Tt][Pp]://*|[Hh][Tt][Tt][Pp][Ss]://*|//*) validate_url "$url_candidate" ;;
      esac
    done
    [[ -z "${BASE_URL:-}" ]] || validate_url "$BASE_URL"

    if [[ "$launcher" == playwright && ( "$subcommand" == test || "$subcommand" == codegen ) ]]; then
      for ((i=arg_start; i<${#SEC_ARGV[@]}; i++)); do
        arg="${SEC_ARGV[i]}"
        [[ "$arg" == -- ]] && break
        if sec_arg_option "$arg" --base-url; then
          option_value
          validate_url "$option_value_result"
          base_url_hosts=$((base_url_hosts + 1))
        elif sec_arg_option "$arg" --config -c; then
          option_value
          config_paths+=("$option_value_result")
        fi
      done
      if [[ -z "${BASE_URL:-}" && "$base_url_hosts" -eq 0 ]]; then
        block "[bash-hook] BLOCKED: playwright test/codegen requires attested BASE_URL or --base-url (rule:prod-guard)." "prod-guard"
      fi
      # Validate every supplied config, including duplicates. For a directory
      # argument use the same supported default filenames as Playwright. Refuse
      # multiple candidates instead of guessing precedence between extensions.
      # An explicit config replaces cwd discovery; BASE_URL never bypasses it.
      if [[ ${#config_paths[@]} -eq 0 ]]; then config_paths=("."); fi
      for config_path in "${config_paths[@]}"; do
        if [[ -d "$config_path" ]]; then
          found_configs=()
          for extension in ts js mts mjs cts cjs; do
            cfg="${config_path%/}/playwright.config.$extension"
            [[ ! -f "$cfg" ]] || found_configs+=("$cfg")
          done
          if [[ ${#found_configs[@]} -gt 1 ]]; then
            block "[bash-hook] BLOCKED: ambiguous Playwright config directory (rule:prod-guard-config)." "prod-guard-config-ambiguous"
          fi
          if [[ ${#found_configs[@]} -eq 1 ]]; then validate_config_file "${found_configs[0]}"; fi
        else
          validate_config_file "$config_path"
        fi
      done
    fi

    # Consume one-shot approval only after launcher, options, URLs and configs
    # are all validated. An approved invocation cannot skip a deny rule.
    if [[ "$snapshot" -eq 1 ]]; then
      if [[ "$launcher" != playwright || "$subcommand" != test ]]; then
        block "[bash-hook] BLOCKED: invalid snapshot command launcher (rule:approval-command)." "approval-command"
      fi
      sec_consume_approval "$APPROVAL_DIR" snapshots "$APPROVAL_MAX_AGE_SEC" "$session_id" "$FLEET_ROOT_FOR_APPROVAL" ||
        block "[bash-hook] BLOCKED: --update-snapshots needs orchestrator approval file hooks/approvals/snapshots (max ${APPROVAL_MAX_AGE_SEC}s, one-shot)." "approval-required"
    elif [[ "$launcher" == playwright && "$subcommand" == install ]]; then
      sec_consume_approval "$APPROVAL_DIR" with-deps "$APPROVAL_MAX_AGE_SEC" "$session_id" "$FLEET_ROOT_FOR_APPROVAL" ||
        block "[bash-hook] BLOCKED: playwright install --with-deps needs orchestrator approval file hooks/approvals/with-deps (max ${APPROVAL_MAX_AGE_SEC}s, one-shot)." "approval-required"
    fi
    ;;
esac

if [[ "$allowed" -eq 1 ]]; then
  audit_decision "allowlist" "allow"
  exit 0
fi
block "[bash-hook] BLOCKED: command not on allowlist for $agent (rule:allowlist)." "allowlist"
