#!/usr/bin/env bash
#
# hook-e2e.test.sh — registration + executable + realistic PreToolUse payload chain.
# Does not invoke Claude Code; live Bash attribution was confirmed in 78f4c0f.
# Write-event agent_type attribution is a documented residual (hooks/xixi/CONTRACT.md).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="${HOOK_PATH:-${HOOK_SRC:-$REPO_ROOT/hooks/restrict-bash-by-agent.sh}}"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"
LIVE_CONTRACT_FILE="${AGENT_CONTRACT_FILE:-$SCRIPT_DIR/fixtures/agent-contract.tsv}"

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

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/home/.claude" "$TMP_ROOT/cwd" "$TMP_ROOT/approvals"

# Parse command words, never evaluate settings as shell code. A hook filename in
# an argument (echo/bash/env ... hook.sh) does not register that executable.
# Resolve argv[0] to the expected source; a same-named unrelated script also fails.
check_registration() {
  python3 - "$SETTINGS" "$1" "$2" "$REPO_ROOT" "$TMP_ROOT" <<'REGISTRATION'
import json, os, pathlib, re, shlex, shutil, subprocess, sys
settings_file, expected, mode, repo, temp = sys.argv[1:]
expected = pathlib.Path(expected).resolve()
try:
    settings = json.loads(pathlib.Path(settings_file).read_text())
    entries = settings.get("hooks", {}).get("PreToolUse", [])
    tools = ("Bash",) if mode == "bash" else ("Write", "Edit")
    commands = {tool: [] for tool in tools}
    for entry in entries:
        matcher = entry.get("matcher", "")
        if mode == "bash" and matcher != "Bash":
            continue
        if not all(re.fullmatch(matcher, tool) for tool in tools):
            continue
        for hook in entry.get("hooks", []):
            if hook.get("type") != "command":
                continue
            raw_command = hook.get("command", "")
            words = shlex.split(raw_command)
            # This fleet registers standalone executable hooks without arguments.
            if len(words) != 1:
                continue
            # Quoted/escaped tildes are literal to the shell, not HOME expansion.
            if words[0].startswith("~") and not raw_command.lstrip().startswith("~"):
                continue
            command = os.path.expanduser(words[0])
            if pathlib.Path(command).name != expected.name:
                continue
            if "/" not in command:
                command = shutil.which(command) or ""
            elif not os.path.isabs(command):
                command = os.path.join(repo, command)
            if not command or pathlib.Path(command).resolve() != expected:
                continue
            if not os.access(command, os.X_OK):
                continue
            for tool in tools:
                commands[tool].append(command)
    if not all(commands.values()):
        raise ValueError("missing executable registration covering " + " and ".join(tools))
    if mode == "write":
        # Exercise both tool events through the matching registered executable.
        # Only the selected self-protection hook is run, never unrelated settings hooks.
        env = {"PATH": os.environ["PATH"], "HOME": temp + "/home",
               "CLAUDE_CONFIG_DIR": temp + "/home/.claude",
               "HOOK_LIB_DIR": repo + "/hooks/lib", "TMPDIR": temp,
               "APPROVAL_DIR": temp + "/approvals"}
        for tool, registered in commands.items():
            for command in registered:
                for protected in (True, False):
                    payload = {"agent_type": "e2e-runner", "tool_name": tool,
                               "hook_event_name": "PreToolUse", "cwd": temp + "/cwd",
                               "tool_input": {"file_path": temp + (
                                   "/home/.claude/settings.json" if protected else "/cwd/test.txt")}}
                    result = subprocess.run([command], input=json.dumps(payload), text=True,
                                            capture_output=True, cwd=temp + "/cwd", env=env)
                    if result.returncode != (2 if protected else 0):
                        raise ValueError(f"{tool} registered chain: exit={result.returncode}: {result.stderr}")
                    if protected:
                        response = json.loads(result.stdout)["hookSpecificOutput"]
                        if (response.get("permissionDecision") != "deny" or
                                "rule:self-protect" not in response.get("permissionDecisionReason", "")):
                            raise ValueError(f"{tool} denied for the wrong reason: {result.stdout}")
except (OSError, ValueError, TypeError, AttributeError, KeyError, re.error) as exc:
    print(f"registration FAIL: {exc}", file=sys.stderr)
    sys.exit(1)
REGISTRATION
}

if [[ -f "$SETTINGS" ]] && command -v python3 >/dev/null 2>&1 \
   && check_registration "$HOOK" bash; then
  pass "settings registers restrict-bash-by-agent.sh under PreToolUse matcher Bash"
else
  fail "restrict-bash-by-agent.sh is not an executable command hook under PreToolUse matcher Bash in $SETTINGS"
fi

WRITE_HOOK="${WRITE_HOOK_PATH:-${WRITE_HOOK_SRC:-$REPO_ROOT/hooks/restrict-mutator-write.sh}}"
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

if [[ -f "$SETTINGS" ]] && command -v python3 >/dev/null 2>&1 \
   && check_registration "$WRITE_HOOK" write; then
  pass "settings registers restrict-mutator-write.sh and its Write/Edit chain allows safe paths and denies protected paths"
else
  fail "restrict-mutator-write.sh registration or registered Write/Edit chain failed in $SETTINGS"
fi

# ADR 0002 removed Bash from every fleet agent, so the executable payload chain can no
# longer be exercised through a live agent. Derive a gate contract that grants e2e-runner
# Bash again, for the registration/parsing chain only. Fleet policy — that the LIVE
# contract denies it — is asserted separately at the end of this suite.
# Kept inside TMP_ROOT so the trap above cleans it up: a second `trap ... EXIT` would
# silently replace that one and leak the temp tree.
AGENT_CONTRACT_FILE="$TMP_ROOT/bash-gate-contract.tsv"
awk -F'|' -v OFS='|' '$1=="e2e-runner"{$2="Read, Write, Edit, Bash, Grep, Glob"}1' \
  "$LIVE_CONTRACT_FILE" > "$AGENT_CONTRACT_FILE"
if ! grep -q '^e2e-runner|Read, Write, Edit, Bash, ' "$AGENT_CONTRACT_FILE"; then
  echo "FATAL: could not derive gate contract from $LIVE_CONTRACT_FILE" >&2
  exit 2
fi
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
  output="$(cd "$SAFE_CWD" && printf '%s' "$payload" | env -i PATH="$PATH" TMPDIR="$TMP_ROOT" CLAUDE_CONFIG_DIR="$TMP_HOME/.claude" HOOK_LIB_DIR="$REPO_ROOT/hooks/lib" E2E_ALLOWED_HOSTS= BASE_URL=http://localhost:3000 HOME="$TMP_HOME" APPROVAL_DIR="$APPROVAL_DIR" AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$AUDIT_LOG" "$HOOK" 2>&1)"
  rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (exit=$rc, want=$expected; output: $(printf '%s' "$output" | tr '\n' ' | '))"
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
attribution_output="$(cd "$SAFE_CWD" && printf '%s' "$main_payload" | env -i PATH="$PATH" TMPDIR="$TMP_ROOT" CLAUDE_CONFIG_DIR="$TMP_HOME/.claude" HOOK_LIB_DIR="$REPO_ROOT/hooks/lib" E2E_ALLOWED_HOSTS= BASE_URL=http://localhost:3000 HOME="$TMP_HOME" APPROVAL_DIR="$APPROVAL_DIR" AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$AUDIT_LOG" "$HOOK" 2>&1)"
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

fail_open_output="$(cd "$SAFE_CWD" && printf '%s' "$allowed_payload" | env -i PATH="$PATH" TMPDIR="$TMP_ROOT" CLAUDE_CONFIG_DIR="$TMP_HOME/.claude" HOOK_LIB_DIR="$REPO_ROOT/hooks/lib" E2E_ALLOWED_HOSTS= BASE_URL=http://localhost:3000 HOME="$TMP_HOME" APPROVAL_DIR="$APPROVAL_DIR" AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$TMP_ROOT/missing/audit.log" "$HOOK" 2>&1)"
fail_open_rc=$?
if [[ "$fail_open_rc" -eq 0 ]]; then
  pass "audit write failure does not change an allow decision"
else
  fail "audit write failure changed allow decision (exit=$fail_open_rc; first output: $(printf '%s' "$fail_open_output" | head -n 1))"
fi

echo
# --- ADR 0002: the live contract must deny Bash to the same payload chain ---
live_denied="$(cd "$SAFE_CWD" && printf '%s' "$allowed_payload" | env -i PATH="$PATH" TMPDIR="$TMP_ROOT" CLAUDE_CONFIG_DIR="$TMP_HOME/.claude" HOOK_LIB_DIR="$REPO_ROOT/hooks/lib" E2E_ALLOWED_HOSTS= BASE_URL=http://localhost:3000 HOME="$TMP_HOME" APPROVAL_DIR="$APPROVAL_DIR" AGENT_CONTRACT_FILE="$LIVE_CONTRACT_FILE" HOOK_AUDIT_LOG="$AUDIT_LOG" "$HOOK" 2>&1)"
live_rc=$?
if [[ "$live_rc" -eq 2 ]] && printf '%s' "$live_denied" | grep -q 'rule:no-bash-tool'; then
  pass "live contract: same allowlisted payload is denied (no Bash tool declared)"
else
  fail "live contract did not deny the e2e payload (exit=$live_rc; output: $(printf '%s' "$live_denied" | tr '\n' ' | '))"
fi

echo "==> result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
