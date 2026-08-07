#!/usr/bin/env bash
# restrict-bash-by-agent.sh — PreToolUse Bash gate for mutator agents (grill F9 / audit-fix).
#
# Canonical path (git): ~/.claude/agents/hooks/restrict-bash-by-agent.sh
# Register in settings.json PreToolUse matcher Bash.
#
# Exit: 0 allow · 2 BLOCK (stderr to model)
#
# Policy:
#   - review-only agents: always block Bash
#   - known mutators: single simple command (no shell operators), allowlist match
#   - main session (no agent_type): pass through
#   - parse failure with mutator-like payload: fail closed
#   - privileged e2e ops: one-shot approval files under hooks/approvals/ (not command text)
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPROVAL_DIR="${HOOKS_DIR}/approvals"
APPROVAL_MAX_AGE_SEC=300

input=$(cat)

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
  if printf '%s' "$input" | grep -qE '"agent_type"[[:space:]]*:[[:space:]]*"(build-error-resolver|tdd-guide|refactor-cleaner|doc-updater|e2e-runner|code-reviewer|security-reviewer|architect|planner|_xixi|xixi)"'; then
    parse_ok=0
  else
    cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    agent=""
    parse_ok=1
  fi
fi

norm=$(printf '%s' "$cmd" | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]\+/ /g')

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

# Parse failure while payload names a restricted agent → fail closed (audit High).
if [[ "$parse_ok" -eq 0 ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    block "[bash-hook] BLOCKED: jq unavailable — cannot attribute agent_type for Bash gate. Install jq."
  fi
  block "[bash-hook] BLOCKED: cannot parse Bash tool payload (rule:parse)."
fi

case "$agent" in
  code-reviewer|security-reviewer|architect|planner|_xixi|xixi)
    block "[bash-hook] BLOCKED: agent_type=$agent must not use Bash (rule:review-only)."
    ;;
esac

case "$agent" in
  build-error-resolver|tdd-guide|refactor-cleaner|doc-updater|e2e-runner) ;;
  "") exit 0 ;; # main session / unknown non-restricted
  *) exit 0 ;;
esac

# --- Mutators only below ---

if [[ -z "$norm" ]]; then
  block "[bash-hook] BLOCKED: empty command (rule:empty)."
fi

# Single simple command: reject shell metacharacters / chaining / substitution.
# Agents must issue one argv-like command per Bash call (no && ; | ` $() etc.).
if printf '%s' "$norm" | grep -qE '[;&|<>`$(){}]|&&|\|\||\$\(|`|\n|\r'; then
  block "[bash-hook] BLOCKED: shell operators/substitutions forbidden for $agent (rule:no-shell-meta). Run one simple command per call."
fi
# Also reject unquoted multi-statement via newline already collapsed; ban backslash escapes for ; 
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

# One-shot approval files (orchestrator/main session creates; agent cannot forge via command text)
consume_approval() {
  # $1 = token name e.g. with-deps | snapshots
  local name="$1" f age now
  f="${APPROVAL_DIR}/${name}"
  if [[ ! -f "$f" ]]; then
    return 1
  fi
  now=$(date +%s)
  # mtime age (macOS stat -f %m, Linux %Y)
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

allowed=0
case "$agent" in
  build-error-resolver)
    if printf '%s' "$norm" | grep -qiE \
      '^(npx[[:space:]]+)?tsc([[:space:]]|$)|^(npm|yarn|pnpm|bun)[[:space:]]+run[[:space:]]+(build|typecheck|lint)([[:space:]]|$)|^eslint[[:space:]]|^cat[[:space:]]|^head[[:space:]]|^tail[[:space:]]|^wc[[:space:]]|^ls([[:space:]]|$)|^pwd$|^git[[:space:]]+(status|diff|log|show|rev-parse|branch)([[:space:]]|$)|^which[[:space:]]|^command[[:space:]]+-v[[:space:]]|^jq[[:space:]]'; then
      if printf '%s' "$norm" | grep -qiE 'eslint.*--fix'; then
        block "[bash-hook] BLOCKED: eslint --fix denied (rule:deny-autofix)."
      fi
      allowed=1
    fi
    ;;
  tdd-guide)
    if printf '%s' "$norm" | grep -qiE \
      '^(npm|yarn|pnpm)[[:space:]]+(test|run[[:space:]]+test|run[[:space:]]+coverage)([[:space:]]|$)|^npx[[:space:]]+(vitest|jest|playwright[[:space:]]+test)([[:space:]]|$)|^bun[[:space:]]+test([[:space:]]|$)|^git[[:space:]]+(status|diff|log|show)([[:space:]]|$)|^cat[[:space:]]|^ls([[:space:]]|$)|^pwd$|^which[[:space:]]|^command[[:space:]]+-v[[:space:]]'; then
      if printf '%s' "$norm" | grep -qiE '(--update-snapshots|[[:space:]]-u([[:space:]]|$))'; then
        block "[bash-hook] BLOCKED: snapshot update denied for tdd-guide (rule:deny-snapshots)."
      fi
      allowed=1
    fi
    ;;
  refactor-cleaner)
    if printf '%s' "$norm" | grep -qiE \
      '^(npx[[:space:]]+)?(knip|depcheck|ts-prune)([[:space:]]|$)|^(npm|yarn|pnpm)[[:space:]]+(test|run[[:space:]]+test|ls)([[:space:]]|$)|^git[[:space:]]+(status|diff|log|show|stash|checkout[[:space:]]+-b|branch|rm|restore)([[:space:]]|$)|^ls([[:space:]]|$)|^cat[[:space:]]|^(rg|grep|find)[[:space:]]|^which[[:space:]]'; then
      allowed=1
    fi
    ;;
  doc-updater)
    if printf '%s' "$norm" | grep -qiE \
      '^(npx[[:space:]]+)?tsx[[:space:]]|^node[[:space:]]|^madge[[:space:]]|^jsdoc|^typedoc|^(npm|yarn|pnpm)[[:space:]]+run[[:space:]]+(docs|codemap|build:docs)([[:space:]]|$)|^git[[:space:]]+(status|diff|log|show)([[:space:]]|$)|^ls([[:space:]]|$)|^cat[[:space:]]|^(find|rg|grep)[[:space:]]|^(mv|mkdir)[[:space:]]|^which[[:space:]]'; then
      allowed=1
    fi
    ;;
  e2e-runner)
    if printf '%s' "$norm" | grep -qiE 'playwright[[:space:]]+install[[:space:]]+--with-deps'; then
      if consume_approval "with-deps"; then
        allowed=1
      else
        block "[bash-hook] BLOCKED: playwright install --with-deps needs orchestrator approval file hooks/approvals/with-deps (max ${APPROVAL_MAX_AGE_SEC}s, one-shot)."
      fi
    elif printf '%s' "$norm" | grep -qiE '(--update-snapshots|[[:space:]]-u([[:space:]]|$))'; then
      if consume_approval "snapshots"; then
        allowed=1
      else
        block "[bash-hook] BLOCKED: --update-snapshots needs orchestrator approval file hooks/approvals/snapshots (max ${APPROVAL_MAX_AGE_SEC}s, one-shot)."
      fi
    elif printf '%s' "$norm" | grep -qiE \
      '^(npx[[:space:]]+)?playwright[[:space:]]+(test|show-report|codegen)([[:space:]]|$)|^(npm|yarn|pnpm)[[:space:]]+(test|run[[:space:]]+test:e2e)([[:space:]]|$)|^git[[:space:]]+(status|diff|log|show)([[:space:]]|$)|^ls([[:space:]]|$)|^cat[[:space:]]|^which[[:space:]]|^command[[:space:]]+-v[[:space:]]'; then
      allowed=1
    fi
    ;;
esac

if [[ "$allowed" -eq 1 ]]; then
  exit 0
fi

block "[bash-hook] BLOCKED: command not on allowlist for $agent (rule:allowlist)."
