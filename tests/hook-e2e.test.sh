#!/usr/bin/env bash
#
# hook-e2e.test.sh — registration + executable + realistic PreToolUse payload chain.
# Does not invoke Claude Code; live Bash attribution was confirmed in 78f4c0f.
# Write-event agent_type attribution is a documented residual (hooks/xixi/CONTRACT.md).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="${HOOK_PATH:-$REPO_ROOT/hooks/restrict-bash-by-agent.sh}"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf 'PASS  %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$1" >&2
}

echo "==> hook E2E: settings registration + executable payload chain"

if [[ ! -f "$SETTINGS" ]]; then
  fail "settings file missing: $SETTINGS"
elif ! grep -qF 'restrict-bash-by-agent.sh' "$SETTINGS"; then
  fail "settings file does not mention restrict-bash-by-agent.sh: $SETTINGS"
elif ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required to validate the PreToolUse registration"
elif python3 - "$SETTINGS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    settings = json.load(fh)

registered = any(
    entry.get("matcher") == "Bash"
    and any(
        hook.get("type") == "command"
        and "restrict-bash-by-agent.sh" in hook.get("command", "")
        for hook in entry.get("hooks", [])
    )
    for entry in settings.get("hooks", {}).get("PreToolUse", [])
)
raise SystemExit(0 if registered else 1)
PY
then
  pass "settings registers restrict-bash-by-agent.sh under PreToolUse matcher Bash"
else
  fail "restrict-bash-by-agent.sh is not a command hook under PreToolUse matcher Bash in $SETTINGS"
fi

WRITE_HOOK="${WRITE_HOOK_PATH:-$REPO_ROOT/hooks/restrict-mutator-write.sh}"
if [[ -x "$HOOK" ]]; then
  pass "hook is executable: $HOOK"
else
  fail "hook is missing or not executable: $HOOK"
fi
if [[ -x "$WRITE_HOOK" ]]; then
  pass "write self-protect hook is executable: $WRITE_HOOK"
else
  fail "write self-protect hook is missing or not executable: $WRITE_HOOK"
fi

if [[ -f "$SETTINGS" ]] && command -v python3 >/dev/null 2>&1 && python3 - "$SETTINGS" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
registered = any(
    "Write" in entry.get("matcher", "")
    and any(
        hook.get("type") == "command"
        and "restrict-mutator-write.sh" in hook.get("command", "")
        for hook in entry.get("hooks", [])
    )
    for entry in settings.get("hooks", {}).get("PreToolUse", [])
)
raise SystemExit(0 if registered else 1)
PY
then
  pass "settings registers restrict-mutator-write.sh under PreToolUse Write|Edit"
else
  fail "restrict-mutator-write.sh is not registered under a Write matcher in $SETTINGS"
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
SAFE_CWD="$TMP_ROOT/cwd"
TMP_HOME="$TMP_ROOT/home"
APPROVAL_DIR="$TMP_ROOT/approvals"
mkdir -p "$SAFE_CWD" "$TMP_HOME" "$APPROVAL_DIR"
AUDIT_LOG="$TMP_ROOT/bash-gate.audit.log"

run_case() {
  local desc="$1" payload="$2" expected="$3" output rc
  if [[ ! -x "$HOOK" ]]; then
    fail "$desc (hook is not executable)"
    return
  fi
  output="$(cd "$SAFE_CWD" && printf '%s' "$payload" | env BASE_URL=http://localhost:3000 HOME="$TMP_HOME" APPROVAL_DIR="$APPROVAL_DIR" HOOK_AUDIT_LOG="$AUDIT_LOG" "$HOOK" 2>&1)"
  rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (exit=$rc, want=$expected; first output: $(printf '%s' "$output" | head -n 1))"
  fi
}

# Claude Code documents agent_type as a common top-level hook field. tool_input
# contains Bash's arguments; nesting agent_type there would not match the harness.
allowed_payload='{"session_id":"e2e-session","transcript_path":"/tmp/e2e-transcript.jsonl","hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"e2e-runner","tool_input":{"command":"node_modules/.bin/playwright test"}}'
blocked_payload='{"session_id":"e2e-session","transcript_path":"/tmp/e2e-transcript.jsonl","hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"e2e-runner","tool_input":{"command":"npx playwright test"}}'
newline_payload='{"session_id":"e2e-session","transcript_path":"/tmp/e2e-transcript.jsonl","hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"e2e-runner","tool_input":{"command":"node_modules/.bin/playwright test\necho unexpected"}}'
main_payload='{"session_id":"main-session","transcript_path":"/tmp/main-transcript.jsonl","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npx playwright test"}}'

run_case "full payload: allowlisted e2e command exits 0" "$allowed_payload" 0
run_case "full payload: bare npx command exits 2" "$blocked_payload" 2
run_case "full payload: newline-containing command exits 2" "$newline_payload" 2
run_case "main-session payload: absent agent_type passes through" "$main_payload" 0

# Attribution is always observable, while the audit log records no command body.
attribution_output="$(cd "$SAFE_CWD" && printf '%s' "$main_payload" | env BASE_URL=http://localhost:3000 HOME="$TMP_HOME" APPROVAL_DIR="$APPROVAL_DIR" HOOK_AUDIT_LOG="$AUDIT_LOG" "$HOOK" 2>&1)"
attribution_rc=$?
if [[ "$attribution_rc" -eq 0 ]] && printf '%s' "$attribution_output" | grep -qF 'agent_type=<absent>'; then
  pass "missing agent_type is observable without constraining main-session Bash"
else
  fail "missing agent_type attribution mismatch (exit=$attribution_rc)"
fi

if grep -Eq '^[0-9]+ agent_type=e2e-runner rule=allowlist decision=allow$' "$AUDIT_LOG" \
   && grep -Eq '^[0-9]+ agent_type=<absent> rule=main-session decision=allow$' "$AUDIT_LOG"; then
  pass "audit log records timestamp, agent_type, rule, and decision"
else
  fail "audit log content mismatch"
fi

fail_open_output="$(cd "$SAFE_CWD" && printf '%s' "$allowed_payload" | env BASE_URL=http://localhost:3000 HOME="$TMP_HOME" APPROVAL_DIR="$APPROVAL_DIR" HOOK_AUDIT_LOG="$TMP_ROOT/missing/audit.log" "$HOOK" 2>&1)"
fail_open_rc=$?
if [[ "$fail_open_rc" -eq 0 ]]; then
  pass "audit write failure does not change an allow decision"
else
  fail "audit write failure changed allow decision (exit=$fail_open_rc; first output: $(printf '%s' "$fail_open_output" | head -n 1))"
fi

echo
echo "==> result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
