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
BASH_HOOK="$TMPD/restrict-bash-by-agent.sh"
cp "$HOOK_SRC" "$BASH_HOOK"
chmod +x "$BASH_HOOK"
HOOK_ROOT="$TMPD"

PASS=0
FAIL=0

echo "==> restrict-bash-by-agent.sh gate tests (isolated HOOK_ROOT=$HOOK_ROOT)"

# bt <desc> <agent> <cmd> <expect-exit> [VAR=VAL ...]
bt() {
  local desc="$1" agent="$2" cmd="$3" exp="$4" rc payload out
  shift 4
  payload=$(jq -nc --arg a "$agent" --arg c "$cmd" '{agent_type:$a, tool_input:{command:$c}}')
  out="$(printf '%s' "$payload" | env "$@" bash "$BASH_HOOK" 2>&1)"
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
bt "unknown future agent passthrough" "some-future-agent" "git status" 0

# --- review-only → always block ---
bt "code-reviewer bash block" "code-reviewer" "git status" 2
bt "security-reviewer bash block" "security-reviewer" "ls" 2
bt "architect bash block" "architect" "cat package.json" 2

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
bt "e2e with-deps block (no approval)" "e2e-runner" "npx playwright install --with-deps" 2
: > "$TMPD/approvals/with-deps"
bt "e2e with-deps allow (approval file)" "e2e-runner" "npx playwright install --with-deps" 0
bt "e2e with-deps consumed (one-shot)" "e2e-runner" "npx playwright install --with-deps" 2
bt "e2e update-snapshots block (no approval)" "e2e-runner" "playwright test --update-snapshots" 2
: > "$TMPD/approvals/snapshots"
bt "e2e update-snapshots allow (approval file)" "e2e-runner" "playwright test --update-snapshots" 0
: > "$TMPD/approvals/snapshots"
touch -t 202001010000 "$TMPD/approvals/snapshots"
bt "e2e update-snapshots stale approval block" "e2e-runner" "playwright test --update-snapshots" 2
: > "$TMPD/approvals/snapshots"
bt "e2e -u cannot borrow approval (block)" "e2e-runner" "python3 -u /tmp/x.py" 2

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

# --- malformed payload → fail closed (only when agent_type names a gated agent) ---
out="$(printf '%s' '{"agent_type":"e2e-runner","tool_input":{' | bash "$BASH_HOOK" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ]; then
  PASS=$((PASS + 1)); echo "PASS  e2e bad JSON fail-closed"
else
  FAIL=$((FAIL + 1)); echo "FAIL  e2e bad JSON fail-closed (exit=$rc, want=2)"
fi

# --- F3-3/M4: settings.json must actually register the hook (runtime wiring) ---
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
  echo "SKIP  settings registration check (SETTINGS=$SETTINGS, python3 unavailable)"
fi

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
