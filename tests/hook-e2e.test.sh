#!/usr/bin/env bash
#
# hook-e2e.test.sh — registration + executable + realistic PreToolUse payload chain.
# Does not invoke Claude Code. The live harness attribution probe remains manual.
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

if [[ -x "$HOOK" ]]; then
  pass "hook is executable: $HOOK"
else
  fail "hook is missing or not executable: $HOOK"
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
SAFE_CWD="$TMP_ROOT/cwd"
TMP_HOME="$TMP_ROOT/home"
mkdir -p "$SAFE_CWD" "$TMP_HOME"

run_case() {
  local desc="$1" payload="$2" expected="$3" output rc
  if [[ ! -x "$HOOK" ]]; then
    fail "$desc (hook is not executable)"
    return
  fi
  output="$(cd "$SAFE_CWD" && printf '%s' "$payload" | env -u BASE_URL HOME="$TMP_HOME" HOOK_DEBUG=0 "$HOOK" 2>&1)"
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

# Exercise the opt-in audit without touching the production log.
mkdir -p "$TMP_HOME/.claude/agents/hooks"
default_output="$(cd "$SAFE_CWD" && printf '%s' "$allowed_payload" | env -u BASE_URL -u HOOK_DEBUG HOME="$TMP_HOME" "$HOOK" 2>&1)"
default_rc=$?
debug_log="$TMP_HOME/.claude/agents/hooks/agent-type.log"
if [[ "$default_rc" -eq 0 && ! -e "$debug_log" ]]; then
  pass "HOOK_DEBUG unset performs no attribution write"
else
  fail "HOOK_DEBUG unset must exit 0 without creating agent-type.log (exit=$default_rc; first output: $(printf '%s' "$default_output" | head -n 1))"
fi

debug_output="$(cd "$SAFE_CWD" && printf '%s' "$allowed_payload" | env -u BASE_URL HOME="$TMP_HOME" HOOK_DEBUG=1 "$HOOK" 2>&1)"
debug_rc=$?
if [[ "$debug_rc" -ne 0 ]]; then
  fail "HOOK_DEBUG attribution invocation exits 0 (exit=$debug_rc; first output: $(printf '%s' "$debug_output" | head -n 1))"
elif [[ ! -f "$debug_log" ]]; then
  fail "HOOK_DEBUG creates agent-type.log"
elif [[ "$(wc -l < "$debug_log" | tr -d ' ')" -ne 1 ]]; then
  fail "HOOK_DEBUG appends exactly one line per invocation"
elif grep -Eq '^[0-9]+ agent_type=e2e-runner tool_name=Bash command=node_modules/\.bin/playwright test$' "$debug_log"; then
  pass "HOOK_DEBUG logs parsed agent_type, tool_name, and command"
else
  fail "HOOK_DEBUG log line has unexpected content: $(head -n 1 "$debug_log")"
fi

long_cmd="node_modules/.bin/playwright test $(printf '%0100d' 0)"
long_payload="$(printf '{\"session_id\":\"e2e-session\",\"transcript_path\":\"/tmp/e2e-transcript.jsonl\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"agent_type\":\"e2e-runner\",\"tool_input\":{\"command\":\"%s\"}}' "$long_cmd")"
long_output="$(cd "$SAFE_CWD" && printf '%s' "$long_payload" | env -u BASE_URL HOME="$TMP_HOME" HOOK_DEBUG=1 "$HOOK" 2>&1)"
long_rc=$?
logged_long_cmd="$(tail -n 1 "$debug_log")"
logged_long_cmd="${logged_long_cmd#* command=}"
if [[ "$long_rc" -eq 0 && "${#logged_long_cmd}" -eq 80 ]]; then
  pass "HOOK_DEBUG truncates the logged command to 80 characters"
else
  fail "HOOK_DEBUG command truncation mismatch (exit=$long_rc, logged_length=${#logged_long_cmd}; first output: $(printf '%s' "$long_output" | head -n 1))"
fi

missing_home="$TMP_HOME/missing-parent"
fail_open_output="$(cd "$SAFE_CWD" && printf '%s' "$allowed_payload" | env -u BASE_URL HOME="$missing_home" HOOK_DEBUG=1 "$HOOK" 2>&1)"
fail_open_rc=$?
if [[ "$fail_open_rc" -eq 0 ]]; then
  pass "HOOK_DEBUG write failure does not change an allow decision"
else
  fail "HOOK_DEBUG write failure changed allow decision (exit=$fail_open_rc; first output: $(printf '%s' "$fail_open_output" | head -n 1))"
fi

fail_open_block_output="$(cd "$SAFE_CWD" && printf '%s' "$blocked_payload" | env -u BASE_URL HOME="$missing_home" HOOK_DEBUG=1 "$HOOK" 2>&1)"
fail_open_block_rc=$?
if [[ "$fail_open_block_rc" -eq 2 ]]; then
  pass "HOOK_DEBUG write failure does not change a deny decision"
else
  fail "HOOK_DEBUG write failure changed deny decision (exit=$fail_open_block_rc; first output: $(printf '%s' "$fail_open_block_output" | head -n 1))"
fi

cat <<'PROBE'

===== MANUAL PROBE BEGIN =====
1. In the terminal that will launch Claude Code, run:
     export HOOK_DEBUG=1
2. Launch/restart Claude Code from that same terminal, then dispatch the real
   e2e-runner subagent and ask it to make one benign Bash call with command: ls
3. After the subagent's Bash call, run in a main/orchestrator Bash tool:
     tail -n 20 ~/.claude/agents/hooks/agent-type.log
4. Confirm the new line has this shape (epoch varies):
     1750000000 agent_type=e2e-runner tool_name=Bash command=ls
   An empty or different agent_type means live harness attribution is not verified.
===== MANUAL PROBE END =====
PROBE

echo
echo "==> result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
