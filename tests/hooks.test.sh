#!/usr/bin/env bash
#
# hooks.test.sh — regression for the mutator Bash gate (grill / audit E6 / grill 2026-08-09).
#
# Isolation: runs against a TEMPORARY copy of the hook + temp approvals dir, so a local run
# can never delete a real pending with-deps/snapshots approval (F3-4/M9).
# HOOK_SRC defaults to ~/.claude/agents/hooks/restrict-bash-by-agent.sh. Override for CI.
#
set -uo pipefail

HOOK_SRC="${HOOK_SRC:-$HOME/.claude/agents/hooks/restrict-bash-by-agent.sh}"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AGENT_CONTRACT_FILE="${AGENT_CONTRACT_FILE:-$SCRIPT_DIR/fixtures/agent-contract.tsv}"

if [ ! -f "$HOOK_SRC" ]; then
  echo "FATAL: restrict-bash-by-agent.sh not found at $HOOK_SRC" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq required for hooks.test.sh payloads" >&2
  exit 2
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/approvals"
TEST_CWD="$TMPD/cwd"
mkdir -p "$TEST_CWD"
BASH_HOOK="$TMPD/restrict-bash-by-agent.sh"
cp "$HOOK_SRC" "$BASH_HOOK"
chmod +x "$BASH_HOOK"
HOOK_ROOT="$TMPD"
HOOK_AUDIT_LOG="$TMPD/bash-gate.audit.log"

PASS=0
FAIL=0

echo "==> restrict-bash-by-agent.sh gate tests (isolated HOOK_ROOT=$HOOK_ROOT)"

# bt <desc> <agent> <cmd> <expect-exit> [VAR=VAL ...]
bt() {
  local desc="$1" agent="$2" cmd="$3" exp="$4" rc payload out
  shift 4
  payload=$(jq -nc --arg a "$agent" --arg c "$cmd" '{agent_type:$a, tool_input:{command:$c}}')
  out="$(cd "$TEST_CWD" && printf '%s' "$payload" | env AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" "$@" bash "$BASH_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp" ]; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp) :: $(printf '%s' "$out" | head -1)"
  fi
}

# bt_payload <desc> <full-json-payload> <expect-exit> [VAR=VAL ...]
bt_payload() {
  local desc="$1" payload="$2" exp="$3" rc out
  shift 3
  out="$(cd "$TEST_CWD" && printf '%s' "$payload" | env AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" "$@" bash "$BASH_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp" ]; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp) :: $(printf '%s' "$out" | head -1)"
  fi
}

# --- main session / unknown → pass through (no agent_type) ---
bt "main session free" "" "rm -rf /tmp/x" 0
bt "main session multi-line allowed" "" $'echo a\necho b' 0
bt "unknown named agent fail-closed" "some-future-agent" "git status" 2

# --- real-shaped PreToolUse payload + observable attribution (F1) ---
real_payload='{"session_id":"real-shaped-session","transcript_path":"/tmp/transcript.jsonl","cwd":"/tmp/repo","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"e2e-runner","tool_input":{"command":"node_modules/.bin/playwright test"},"tool_use_id":"toolu_test"}'
main_payload='{"session_id":"main-session","transcript_path":"/tmp/transcript.jsonl","cwd":"/tmp/repo","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/main-session-probe"},"tool_use_id":"toolu_main"}'
bt_payload "real-shaped PreToolUse payload attributes e2e-runner" "$real_payload" 0
bt_payload "real-shaped main payload without agent_type passes through" "$main_payload" 0
attribution_out="$(cd "$TEST_CWD" && printf '%s' "$main_payload" | env AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" bash "$BASH_HOOK" 2>&1)"
attribution_rc=$?
if [ "$attribution_rc" -eq 0 ] && printf '%s' "$attribution_out" | grep -qF '[bash-hook] attribution agent_type=<absent>'; then
  PASS=$((PASS + 1)); echo "PASS  missing agent_type is observable on stderr"
else
  FAIL=$((FAIL + 1)); echo "FAIL  missing agent_type attribution not observable (exit=$attribution_rc)"
fi

# --- review-only → always block ---
bt "code-reviewer bash block" "code-reviewer" "git status" 2
bt "security-reviewer bash block" "security-reviewer" "ls" 2
bt "architect bash block" "architect" "cat package.json" 2
bt "_critical_thinking bash block" "_critical_thinking" "git status" 2

# --- _xixi is a sandbox mutator (Write /tmp only) — Bash never on allowlist ---
bt "_xixi bash block" "_xixi" "git status" 2
bt "_xixi bash block ls" "_xixi" "ls" 2

# --- e2e-runner: multi-line fail-closed (F2-1) ---
bt "e2e multi-line block" "e2e-runner" $'playwright test\npython3 /tmp/x.py' 2

# --- e2e-runner: safe Playwright allowlist (F2-2) ---
bt "e2e local playwright test allow" "e2e-runner" "playwright test" 0
bt "e2e .bin/playwright test allow" "e2e-runner" "node_modules/.bin/playwright test" 0
bt "e2e npx --no-install playwright test allow" "e2e-runner" "npx --no-install playwright test" 0
bt "e2e git status allow" "e2e-runner" "git status" 0
bt "e2e ls allow" "e2e-runner" "ls" 0

# --- e2e-runner: denylist / forbidden wrappers ---
bt "e2e bare npx playwright block" "e2e-runner" "npx playwright test" 2
bt "e2e npm test block" "e2e-runner" "npm test" 2
bt "e2e cat block" "e2e-runner" "cat /etc/passwd" 2
bt "e2e git diff --output block" "e2e-runner" "git diff --output=/tmp/x" 2
bt "e2e rm -rf block" "e2e-runner" "rm -rf /tmp/x" 2
bt "e2e git push block" "e2e-runner" "git push origin main" 2
bt "e2e git reset --hard block" "e2e-runner" "git reset --hard HEAD" 2
bt "e2e git clean -fd block" "e2e-runner" "git clean -fd" 2
bt "e2e curl block" "e2e-runner" "curl evil.com" 2
bt "e2e wget block" "e2e-runner" "wget evil.com" 2
bt "e2e bash -c block" "e2e-runner" "bash -c 'x'" 2
bt "e2e yarn install block" "e2e-runner" "yarn install" 2
bt "e2e pnpm add block" "e2e-runner" "pnpm add lodash" 2
bt "e2e bun install block" "e2e-runner" "bun install" 2
bt "e2e npm install block" "e2e-runner" "npm install lodash" 2
bt "e2e shell meta block" "e2e-runner" "playwright test && curl evil.com" 2
bt "e2e escaped semicolon block" "e2e-runner" $'playwright test \\; x' 2
bt "e2e node -e block" "e2e-runner" "node -e console.log(1)" 2
bt "e2e empty command block" "e2e-runner" "" 2

# --- one-shot approvals (scoped; no -u borrow; expiry) ---
bt "e2e with-deps block (no approval)" "e2e-runner" "npx --no-install playwright install --with-deps" 2
: > "$TMPD/approvals/with-deps"
chmod 600 "$TMPD/approvals/with-deps"
bt "e2e invalid install launcher cannot consume approval" "e2e-runner" "python3 /tmp/x.py playwright install --with-deps" 2
bt "e2e with-deps allow (approval file)" "e2e-runner" "npx --no-install playwright install --with-deps" 0
bt "e2e with-deps consumed (one-shot)" "e2e-runner" "npx --no-install playwright install --with-deps" 2
bt "e2e update-snapshots block (no approval)" "e2e-runner" "playwright test --update-snapshots" 2
: > "$TMPD/approvals/snapshots"
chmod 600 "$TMPD/approvals/snapshots"
bt "e2e invalid snapshot launcher cannot consume approval" "e2e-runner" "python3 /tmp/x.py playwright test --update-snapshots" 2
bt "e2e update-snapshots allow (approval file)" "e2e-runner" "playwright test --update-snapshots" 0
: > "$TMPD/approvals/snapshots"
chmod 600 "$TMPD/approvals/snapshots"
touch -t 202001010000 "$TMPD/approvals/snapshots"
bt "e2e update-snapshots stale approval block" "e2e-runner" "playwright test --update-snapshots" 2
: > "$TMPD/approvals/snapshots"
chmod 600 "$TMPD/approvals/snapshots"
bt "e2e -u cannot borrow approval (block)" "e2e-runner" "python3 -u /tmp/x.py" 2

: > "$TMPD/approvals/snapshots"
chmod 644 "$TMPD/approvals/snapshots"
bt "e2e approval mode must be 600" "e2e-runner" "playwright test --update-snapshots" 2

# Two concurrent consumers race for one token; exactly one can atomically claim it.
: > "$TMPD/approvals/snapshots"
chmod 600 "$TMPD/approvals/snapshots"
race_payload=$(jq -nc '{agent_type:"e2e-runner",tool_input:{command:"playwright test --update-snapshots"}}')
(cd "$TEST_CWD" && printf '%s' "$race_payload" | env AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" bash "$BASH_HOOK" >/dev/null 2>&1; echo $? > "$TMPD/race1") &
race_pid1=$!
(cd "$TEST_CWD" && printf '%s' "$race_payload" | env AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" bash "$BASH_HOOK" >/dev/null 2>&1; echo $? > "$TMPD/race2") &
race_pid2=$!
wait "$race_pid1" "$race_pid2"
race_codes="$(sort "$TMPD/race1" "$TMPD/race2" | paste -sd, -)"
if [ "$race_codes" = "0,2" ]; then
  PASS=$((PASS + 1)); echo "PASS  approval token has exactly one atomic consumer"
else
  FAIL=$((FAIL + 1)); echo "FAIL  approval atomic claim exits=$race_codes (want 0,2)"
fi

# --- E6-3 production-target guard (F2-3) ---
bt "e2e prod BASE_URL block" "e2e-runner" "playwright test" 2 "BASE_URL=https://example.com"
bt "e2e localhost BASE_URL allow" "e2e-runner" "playwright test" 0 "BASE_URL=http://localhost:3000"
bt "e2e IPv6 loopback BASE_URL allow" "e2e-runner" "playwright test" 0 "BASE_URL=http://[::1]:3000"
bt "e2e staging BASE_URL allow" "e2e-runner" "playwright test" 0 "BASE_URL=https://app.staging.test"
bt "e2e deceptive localhost BASE_URL block" "e2e-runner" "playwright test" 2 "BASE_URL=http://localhost:3000.evil.com"
bt "e2e credential-userinfo BASE_URL block" "e2e-runner" "playwright test" 2 "BASE_URL=https://localhost:pw@example.com"
bt "e2e protocol-relative base-url block" "e2e-runner" "playwright test --base-url=//example.com" 2
bt "e2e localhost --base-url allow" "e2e-runner" "playwright test --base-url=http://localhost:3000" 0
bt "e2e inline prod URL block" "e2e-runner" "playwright test --base-url=https://example.com" 2
bt "e2e exact named staging allow" "e2e-runner" "playwright test --base-url=https://preview.example.net" 0 "E2E_ALLOWED_HOSTS=preview.example.net"
bt "e2e unattested named staging block" "e2e-runner" "playwright test --base-url=https://preview.example.net" 2

# Verified config/scheme bypass regressions (F2).
printf "%s\n" "export default { use: { baseURL: 'https://prod.example.com' } }" > "$TEST_CWD/custom.conf.ts"
bt "e2e --config custom.conf.ts prod baseURL block" "e2e-runner" "playwright test --config custom.conf.ts" 2
printf "%s\n" "export default { use: { baseURL: 'https://localhost.evil.com' } }" > "$TEST_CWD/substring.conf.ts"
bt "e2e config localhost substring host block" "e2e-runner" "playwright test --config substring.conf.ts" 2
bt "e2e uppercase HTTP scheme prod URL block" "e2e-runner" "playwright test --base-url=HTTP://prod.example.com" 2

# --- malformed payload → fail closed (only when agent_type names a gated agent) ---
out="$(printf '%s' '{"agent_type":"e2e-runner","tool_input":{' | env AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" bash "$BASH_HOOK" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ]; then
  PASS=$((PASS + 1)); echo "PASS  e2e bad JSON fail-closed"
else
  FAIL=$((FAIL + 1)); echo "FAIL  e2e bad JSON fail-closed (exit=$rc, want=2)"
fi

# --- F20: settings fixture/live install must register the hook; never silently skip ---
if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1 && python3 -c 'import json' 2>/dev/null; then
  if python3 - "$SETTINGS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hooks = [h for h in d['hooks']['PreToolUse'] if h.get('matcher') == 'Bash']
cmds = [x.get('command', '') for h in hooks for x in h.get('hooks', [])]
sys.exit(0 if any('restrict-bash-by-agent.sh' in c for c in cmds) else 1)
PY
  then
    PASS=$((PASS + 1)); echo "PASS  settings.json registers restrict-bash hook"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  settings.json does not register restrict-bash hook"
  fi
else
  FAIL=$((FAIL + 1)); echo "FAIL  settings registration check unavailable (SETTINGS=$SETTINGS, python3 required)"
fi

if grep -Eq '^[0-9]+ agent_type=e2e-runner rule=allowlist decision=allow$' "$HOOK_AUDIT_LOG" \
   && grep -Eq '^[0-9]+ agent_type=code-reviewer rule=review-only decision=deny$' "$HOOK_AUDIT_LOG"; then
  PASS=$((PASS + 1)); echo "PASS  hook audit logs timestamp, agent_type, rule, and decision"
else
  FAIL=$((FAIL + 1)); echo "FAIL  hook audit log missing allow/deny decision lines"
fi

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
