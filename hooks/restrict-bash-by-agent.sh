#!/usr/bin/env bash
# restrict-bash-by-agent.sh — PreToolUse Bash gate for the 7-role fleet.
#
# Policy is chosen by the contract flag (column 5):
#   review_only  → Bash denied
#   review_cli   → Bash limited to the pinned external-CLI wrapper
#                  (bash tools/agent-cli.sh <role>, ADR 0008); no other command
#   mutator      → Bash requires the declared Bash tool; the legacy allowlist applies
#   executor     → Bash requires the declared Bash tool AND the execution-only
#                  allowlist in hooks/lib/executor.sh (ADR 0006)
#   orchestrator → Write/Edit plus the executor allowlist with standing git write
#                  authority, including push/reset/clean (ADR 0007)
# Self-protection at the Bash layer is best-effort, not a sandbox: accepted residual
# recorded in ADR 0006. The Write/Edit layer keeps absolute self-protection.
#
# Canonical path (git): ~/.claude/agents/hooks/restrict-bash-by-agent.sh
# Register in the host that actually loads hooks. Claude: settings.json.
# Grok: ~/.grok/hooks/agent-gates.json (compat.claude.hooks is off).
# This file existing does not register the hook. MUST stay executable (chmod 755).
#
# Field names: Claude sends agent_type / tool_input / session_id.
# Grok sends subagentType / toolInput / sessionId. Both are accepted.
# Neither identity field → main-session pass-through. Disagreeing pairs deny.
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
# Execution-only allowlist for the three executor roles (ADR 0006). Sourced
# optionally, deliberately NOT fail-closed here: a missing library must not lock
# the main session. The executor branch below denies when the function is absent.
if [[ -f "${LIB_DIR}/executor.sh" ]]; then
  source "${LIB_DIR}/executor.sh"
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
EXECUTOR=0
ORCHESTRATOR=0
REVIEW_CLI=0

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
# Type-check each object before indexing it. A single try around .tool_input
# never reaches toolInput when tool_input is a non-object (jq errors, catch
# swallows the alternative). Empty strings are absent so they cannot hide the
# other spelling. Two different non-empty values is a conflict, not a choice.
if ! printf '%s' "$input" | jq -e '
  def take: select(type == "string" and length > 0);
  def at_most_one($xs): ($xs | map(take) | unique | length) <= 1;
  (.agent_type == null or (.agent_type | type == "string")) and
  (.subagentType == null or (.subagentType | type == "string")) and
  (.session_id == null or (.session_id | type == "string")) and
  (.sessionId == null or (.sessionId | type == "string")) and
  ([.. | strings | contains("\u0000")] | any | not) and
  at_most_one([.agent_type, .subagentType]) and
  at_most_one([.session_id, .sessionId]) and
  at_most_one(
    (if (.tool_input | type) == "object" then [.tool_input.command, .tool_input.cmd] else [] end)
    + (if (.toolInput | type) == "object" then [.toolInput.command, .toolInput.cmd] else [] end)
  )
' >/dev/null 2>&1; then
  block "[bash-hook] BLOCKED: invalid attribution, field conflict, or NUL in payload (rule:schema)." "schema"
fi
# The sentinel preserves trailing newlines so command substitution cannot hide
# a multiline command or turn a newline-only agent name into the main session.
cmd=$(printf '%s' "$input" | jq -r '
  def take: select(type == "string" and length > 0);
  try (
    (
      (if (.tool_input | type) == "object" then [.tool_input.command, .tool_input.cmd] else [] end)
      + (if (.toolInput | type) == "object" then [.toolInput.command, .toolInput.cmd] else [] end)
    ) | map(take) | unique | .[0] // empty
  ) catch empty
' 2>/dev/null || true; printf '.')
cmd="${cmd%.}"; cmd="${cmd%$'\n'}"
agent=$(printf '%s' "$input" | jq -r '
  def take: select(type == "string" and length > 0);
  try ([.agent_type, .subagentType] | map(take) | unique | .[0] // empty) catch empty
' 2>/dev/null || true; printf '.')
agent="${agent%.}"; agent="${agent%$'\n'}"
session_id=$(printf '%s' "$input" | jq -r '
  def take: select(type == "string" and length > 0);
  try ([.session_id, .sessionId] | map(take) | unique | .[0] // empty) catch empty
' 2>/dev/null || true; printf '.')
session_id="${session_id%.}"; session_id="${session_id%$'\n'}"
observe_attribution

if [[ -z "$agent" ]]; then
  audit_decision "main-session" "allow"
  exit 0
fi

if [[ ! -r "$AGENT_CONTRACT_FILE" ]]; then
  block "[bash-hook] BLOCKED: agent contract unavailable (rule:contract)." "contract-missing"
fi

# Abstaining on an external identity is only sound while the gate can still establish
# what its own scope IS. An empty, truncated or malformed contract means it cannot, so
# every attributed call is denied until the contract is intact again (ADR 0005).
contract_rows="$(awk -F'|' 'BEGIN{n=0} /^[[:space:]]*(#|$)/ {next} NF==5 && $1 != "" {n++} END{print n+0}' "$AGENT_CONTRACT_FILE" 2>/dev/null || printf '0')"
if [[ ! "$contract_rows" =~ ^[0-9]+$ || "$contract_rows" -lt 1 ]]; then
  block "[bash-hook] BLOCKED: fleet contract has no usable rows — scope cannot be established (rule:contract-unusable)." "contract-unusable"
fi

agent_policy="$(awk -F'|' -v target="$agent" '$1 == target { print $5; exit }' "$AGENT_CONTRACT_FILE" 2>/dev/null || true)"
case "$agent_policy" in
  review_only)
    block "[bash-hook] BLOCKED: agent_type=$agent must not use Bash (rule:review-only)." "review-only"
    ;;
  # Review roles that delegate to an external CLI (ADR 0008). They are still not
  # writers and get no general shell: the only admitted command is the pinned
  # wrapper, which owns the CLI, model and sandbox flags.
  review_cli) REVIEW_CLI=1 ;;
  mutator) ;;
  # Executor roles (ADR 0006): write + run. The allowlist is applied after the
  # global deny rules; it never grants a generic shell.
  executor) EXECUTOR=1 ;;
  orchestrator) ORCHESTRATOR=1 ;;
  "")
    # Absent from the contract. That is either an agent this fleet does not govern, or
    # a contract that has lost a row — and the two must not be confused (ADR 0005).
    #
    # The discriminator is the definition on disk: a fleet agent always has
    # <name>.md at the fleet root. Present without a contract row means the contract
    # is damaged, and damage denies. Absent means the identity is genuinely external.
    #
    # A single stat, deliberately not a directory scan: this runs on the PreToolUse hot
    # path for every Bash call on the machine.
    if [[ -f "${FLEET_ROOT_FOR_APPROVAL}/${agent}.md" ]]; then
      block "[bash-hook] BLOCKED: $agent has a fleet definition but no contract row — the fleet contract is damaged (rule:contract-incomplete)." "contract-incomplete"
    fi
    # Out of scope. Exit 0 means "this hook makes no authorization decision", NOT a
    # grant: whatever the host permits for that agent still applies. Denying here was
    # broader denial, not stronger safety — it has no policy to enforce for an agent it
    # did not define, and it degraded real work (a review of this repo lost git access
    # and reviewed the wrong commit).
    audit_decision "out-of-scope" "abstain"
    exit 0
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

# Audit B6: tokenization walks the command character by character in Bash 3.2.
# Measured on this fleet: 8 KiB ~2.7s, 32 KiB ~37s, against a 5s hook timeout.
# Cap before any parsing so an oversized command fails predictably instead of
# stalling the gate.
MAX_COMMAND_BYTES=16384
if [[ "${#cmd}" -gt "$MAX_COMMAND_BYTES" ]]; then
  block "[bash-hook] BLOCKED: command exceeds ${MAX_COMMAND_BYTES} bytes (rule:command-too-long)." "command-too-long"
fi

# --- Review roles with a pinned CLI route (ADR 0008) ---
# Exactly one admitted shape: bash <fleet>/tools/agent-cli.sh <role> [words...].
# The role selector must match the attributed caller. These roles still hold no
# general shell; the wrapper fixes CLI, model and the sandbox flags, and
# refuses options of its own.
if [[ "$REVIEW_CLI" -eq 1 ]]; then
  declare -F exec_is_agent_cli >/dev/null 2>&1 ||
    block "[bash-hook] BLOCKED: CLI dispatcher policy library missing (rule:lib)." "lib"
  if ! sec_cmd_tokenize "$cmd"; then
    block "[bash-hook] BLOCKED: empty, ambiguous, or unsupported shell command (rule:no-shell-meta)." "no-shell-meta"
  fi
  case "${SEC_ARGV[0]:-}" in
    bash) ;;
    *) block "[bash-hook] BLOCKED: review role $agent may only run tools/agent-cli.sh via bash (rule:allowlist)." "allowlist" ;;
  esac
  if [[ ${#SEC_ARGV[@]} -lt 4 ]] ||
     ! exec_is_agent_cli "$FLEET_ROOT_FOR_APPROVAL" "${SEC_ARGV[1]}" "${SEC_ARGV[2]}" "$agent" "${SEC_ARGV[@]:3}"; then
    block "[bash-hook] BLOCKED: review role $agent may only run tools/agent-cli.sh $agent <prompt> (rule:allowlist)." "allowlist"
  fi
  audit_decision "cli-dispatch" "allow"
  exit 0
fi

# --- Mutators only below ---

# Tokenize once. Every command policy below consumes SEC_ARGV, not cmd.
if ! sec_cmd_tokenize "$cmd"; then
  block "[bash-hook] BLOCKED: empty, ambiguous, or unsupported shell command (rule:no-shell-meta)." "no-shell-meta"
fi
# Executor and orchestrator roles invoking their own bound external-CLI wrapper
# route use the same wrapper validation rule as review_cli, before
# sec_cmd_is_network_or_escape scans prompt text for words like `curl` (audit #11).
if [[ "$EXECUTOR" -eq 1 || "$ORCHESTRATOR" -eq 1 ]] &&
   [[ "${SEC_ARGV[0]:-}" == "bash" && ${#SEC_ARGV[@]} -ge 4 ]] &&
   declare -F exec_is_agent_cli >/dev/null 2>&1 &&
   exec_is_agent_cli "$FLEET_ROOT_FOR_APPROVAL" "${SEC_ARGV[1]}" "${SEC_ARGV[2]}" "$agent" "${SEC_ARGV[@]:3}"; then
  audit_decision "allowlist" "allow"
  exit 0
fi
if sec_cmd_is_destructive "${SEC_ARGV[@]}"; then
  # ADR 0007: the orchestrator holds standing authorization for git push/reset/clean;
  # whether this particular argv is one of them is decided by exec_is_git_write below.
  # Every other destructive command still denies.
  if [[ "$ORCHESTRATOR" -eq 1 && "${SEC_ARGV[0]}" == git ]]; then
    :
  else
    block "[bash-hook] BLOCKED: destructive command denied (rule:deny-destructive)." "deny-destructive"
  fi
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
# Executor policy (ADR 0006). Placed immediately after allowed=0 and before the
# legacy e2e-runner branch; nothing below may reset an allowed executor decision.
# The main session exited above, and a review-only agent was blocked above, so
# only an agent whose contract flag is `executor` can reach this block.
if [[ "$EXECUTOR" -eq 1 || "$ORCHESTRATOR" -eq 1 ]]; then
  if [[ "$ORCHESTRATOR" -eq 1 ]]; then
    declare -F exec_orchestrator_cmd_allowed >/dev/null 2>&1 ||
      block "[bash-hook] BLOCKED: orchestrator policy library missing (rule:lib)." "lib"
    exec_orchestrator_cmd_allowed "$FLEET_ROOT_FOR_APPROVAL" "${SEC_ARGV[@]}" ||
      block "[bash-hook] BLOCKED: command not on orchestrator allowlist for $agent (rule:allowlist)." "allowlist"
  else
    declare -F exec_cmd_allowed >/dev/null 2>&1 ||
      block "[bash-hook] BLOCKED: executor policy library missing (rule:lib)." "lib"
    exec_cmd_allowed "$FLEET_ROOT_FOR_APPROVAL" "${SEC_ARGV[@]}" ||
      block "[bash-hook] BLOCKED: command not on executor allowlist for $agent (rule:allowlist)." "allowlist"
  fi
  allowed=1
fi

# Legacy e2e-runner allowlist (retained for the parser/approval coverage pinned by
# tests/hooks.test.sh, tests/hook-e2e.test.sh, tests/p1-bypass.test.sh and
# tests/p3-approval-binding.test.sh). The live contract has no e2e-runner row; those
# suites synthesize one, so this branch is reachable only under a test contract.
# The fleet no longer defines an e2e-runner identity.
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
