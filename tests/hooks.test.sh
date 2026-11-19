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
WRITE_HOOK_SRC="${WRITE_HOOK_SRC:-$(dirname -- "$HOOK_SRC")/restrict-mutator-write.sh}"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIVE_CONTRACT_SRC="$SCRIPT_DIR/fixtures/agent-contract.tsv"

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
TEST_HOME="$TMPD/home"
TEST_CONFIG="$TEST_HOME/.claude"
mkdir -p "$TEST_CONFIG"
# Read the installation for the registration assertions, then use only its snapshot.
cp "$SETTINGS" "$TEST_CONFIG/settings.json" || exit 2
SETTINGS="$TEST_CONFIG/settings.json"
LIVE_CONTRACT_FILE="$TMPD/live-contract.tsv"
cp "$LIVE_CONTRACT_SRC" "$LIVE_CONTRACT_FILE" || exit 2
TEST_CWD="$TMPD/cwd"
mkdir -p "$TEST_CWD"
BASH_HOOK="$TMPD/restrict-bash-by-agent.sh"
cp "$HOOK_SRC" "$BASH_HOOK"
chmod +x "$BASH_HOOK"
if [[ -d "$(dirname "$HOOK_SRC")/lib" ]]; then
  cp -R "$(dirname "$HOOK_SRC")/lib" "$TMPD/lib"
fi
# Isolated fleet tree so restrict-mutator-write.sh derives FLEET_ROOT from its dirname.
FLEET_FAKE="$TMPD/fleet"
mkdir -p "$FLEET_FAKE/hooks/approvals" "$FLEET_FAKE/tests/fixtures"
WRITE_HOOK="$FLEET_FAKE/hooks/restrict-mutator-write.sh"
if [[ -f "$WRITE_HOOK_SRC" ]]; then
  cp "$WRITE_HOOK_SRC" "$WRITE_HOOK"
  chmod +x "$WRITE_HOOK"
fi
if [[ -d "$TMPD/lib" ]]; then
  cp -R "$TMPD/lib" "$FLEET_FAKE/hooks/lib"
fi
: > "$FLEET_FAKE/hooks/restrict-bash-by-agent.sh"
: > "$FLEET_FAKE/tests/fixtures/agent-contract.tsv"
HOOK_ROOT="$TMPD"
HOOK_AUDIT_LOG="$TMPD/bash-gate.audit.log"

# The live fleet has no e2e-runner identity, but the legacy allowlist and its
# command parser still exist and still need coverage. Synthesize an e2e-runner row
# in the GATE contract for parser/allowlist assertions only. The live 7-role policy
# is asserted separately against LIVE_CONTRACT_FILE below.
GATE_CONTRACT_FILE="$TMPD/bash-gate-contract.tsv"
awk -F'|' -v OFS='|' '$1=="e2e-runner"{$2="Read, Write, Edit, Bash, Grep, Glob"}1' \
  "$LIVE_CONTRACT_FILE" > "$GATE_CONTRACT_FILE"
if ! grep -q '^e2e-runner|' "$GATE_CONTRACT_FILE"; then
  printf '%s\n' 'e2e-runner|Read, Write, Edit, Bash, Grep, Glob|sonnet|PASSING;QUARANTINE;FAILING;NOT RUN|mutator' \
    >> "$GATE_CONTRACT_FILE"
fi
# The 7-role live contract has no mutator lacking Bash, so synthesize one to keep
# the tool-set gate (authority derived from column 2) under test.
if ! grep -q '^probe-mutator|' "$GATE_CONTRACT_FILE"; then
  printf '%s\n' 'probe-mutator|Read, Write, Edit, Grep, Glob|inherit|GO;BLOCK;NEEDS_INPUT|mutator' \
    >> "$GATE_CONTRACT_FILE"
fi
if ! grep -q '^e2e-runner|Read, Write, Edit, Bash, ' "$GATE_CONTRACT_FILE"; then
  echo "FATAL: could not derive gate contract from $LIVE_CONTRACT_FILE" >&2
  exit 2
fi
AGENT_CONTRACT_FILE="$GATE_CONTRACT_FILE"

# Every invocation, including raw payloads, Write/Edit and racing consumers, starts
# clean. Per-case overrides below are literals owned by this suite, not caller state.
HOOK_ENV=(env -i PATH="$PATH" HOME="$TEST_HOME" TMPDIR="$TMPD"
  CLAUDE_CONFIG_DIR="$TEST_CONFIG" HOOK_LIB_DIR="$TMPD/lib"
  APPROVAL_DIR="$TMPD/approvals" AGENT_CONTRACT_FILE="$GATE_CONTRACT_FILE"
  HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" BASE_URL= E2E_ALLOWED_HOSTS=)

# Approval tokens carry a session and repo binding since audit #21; an empty file is
# refused. Mint them the way the orchestrator does so these tests exercise the real
# format rather than a shape the gate no longer accepts.
TEST_SESSION="hooks-test-session"
mint_approval() {
  local name="$1"
  rm -f "$TMPD/approvals/$name" "$TMPD/approvals/$name".consuming.* 2>/dev/null || true
  {
    printf 'session=%s\n' "$TEST_SESSION"
    printf 'repo=%s\n' "$(cd "$(dirname -- "$BASH_HOOK")/.." && pwd -P)"
  } > "$TMPD/approvals/$name"
  chmod 600 "$TMPD/approvals/$name"
}

PASS=0
FAIL=0

echo "==> restrict-bash-by-agent.sh gate tests (isolated HOOK_ROOT=$HOOK_ROOT)"

# bt <desc> <agent> <cmd> <expect-exit> [VAR=VAL ...]
bt() {
  local desc="$1" agent="$2" cmd="$3" exp="$4" rc payload out
  shift 4
  payload=$(jq -nc --arg a "$agent" --arg c "$cmd" --arg s "$TEST_SESSION" \
    '{session_id:$s, agent_type:$a, tool_input:{command:$c}}')
  out="$(cd "$TEST_CWD" && printf '%s' "$payload" | "${HOOK_ENV[@]}" AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" "$@" bash "$BASH_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp" ]; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp) :: $(printf '%s' "$out" | tr '\n' ' | ')"
  fi
}

# bt_rule <desc> <agent> <cmd> <expect-exit> <expect-rule-substring> [VAR=VAL ...]
# Asserts WHY a command was denied, not merely that it was. Several approval tests
# used to pass while the production guard rejected them first for a missing BASE_URL,
# so they stayed green even with the approval logic deleted (audit #18).
bt_rule() {
  local desc="$1" agent="$2" cmd="$3" exp="$4" want_rule="$5" rc payload out
  shift 5
  payload=$(jq -nc --arg a "$agent" --arg c "$cmd" --arg s "$TEST_SESSION" \
    '{session_id:$s, agent_type:$a, tool_input:{command:$c}}')
  out="$(cd "$TEST_CWD" && printf '%s' "$payload" | "${HOOK_ENV[@]}" AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" "$@" bash "$BASH_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp" ] && printf '%s' "$out" | grep -q -- "$want_rule"; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc want=$exp; rule '$want_rule' not found) :: $(printf '%s' "$out" | tr '\n' ' | ')"
  fi
}

# bt_payload <desc> <full-json-payload> <expect-exit> [VAR=VAL ...]
bt_payload() {
  local desc="$1" payload="$2" exp="$3" rc out
  shift 3
  out="$(cd "$TEST_CWD" && printf '%s' "$payload" | "${HOOK_ENV[@]}" AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" "$@" bash "$BASH_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp" ]; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp) :: $(printf '%s' "$out" | tr '\n' ' | ')"
  fi
}

# --- main session / unknown → pass through (no agent_type) ---
bt "main session free" "" "rm -rf /tmp/x" 0
bt "main session multi-line allowed" "" $'echo a\necho b' 0
# ADR 0005 narrowed this. An identity with no fleet definition on disk is one this gate
# does not govern, so it abstains (exit 0 — no authorization decision, host controls
# still apply) rather than denying an agent it has no policy for. Fail-closed still
# holds INSIDE scope: see tests/p3-gate-scope.test.sh, where a fleet agent whose
# contract row was deleted, an empty policy field, and an unusable contract all deny.
bt "unknown external agent is out of scope" "some-future-agent" "git status" 0

# --- real-shaped PreToolUse payload + observable attribution (F1) ---
real_payload='{"session_id":"real-shaped-session","transcript_path":"/tmp/transcript.jsonl","cwd":"/tmp/repo","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"e2e-runner","tool_input":{"command":"node_modules/.bin/playwright test"},"tool_use_id":"toolu_test"}'
main_payload='{"session_id":"main-session","transcript_path":"/tmp/transcript.jsonl","cwd":"/tmp/repo","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/main-session-probe"},"tool_use_id":"toolu_main"}'
bt_payload "real-shaped PreToolUse payload attributes e2e-runner" "$real_payload" 0 "BASE_URL=http://localhost:3000"
bt_payload "real-shaped main payload without agent_type passes through" "$main_payload" 0
attribution_out="$(cd "$TEST_CWD" && printf '%s' "$main_payload" | "${HOOK_ENV[@]}" AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" bash "$BASH_HOOK" 2>&1)"
attribution_rc=$?
if [ "$attribution_rc" -eq 0 ] && printf '%s' "$attribution_out" | grep -qF '[bash-hook] attribution agent_type=<absent>'; then
  PASS=$((PASS + 1)); echo "PASS  missing agent_type is observable on stderr"
else
  FAIL=$((FAIL + 1)); echo "FAIL  missing agent_type attribution not observable (exit=$attribution_rc)"
fi

# --- review-only → always block ---
bt "mark bash block" "mark" "git status" 2
bt "octavion bash block" "octavion" "ls" 2
bt "atia bash block" "atia" "cat package.json" 2
# --- orchestrator: standing git write authority (ADR 0007) ---
bt "anthory git status allow" "anthory" "git status" 0
bt "anthory git add allow" "anthory" "git add ." 0
bt "anthory git commit allow" "anthory" 'git commit -m "fix: x"' 0
bt "anthory git push allow" "anthory" "git push origin main" 0
bt "anthory git reset --hard allow" "anthory" "git reset --hard HEAD~1" 0
bt "anthory git clean allow" "anthory" "git clean -fd" 0
bt_rule "anthory bare --force push denied" "anthory" "git push --force origin main" 2 "rule:allowlist"
bt_rule "anthory --mirror push denied" "anthory" "git push --mirror origin" 2 "rule:allowlist"
bt_rule "anthory git config denied" "anthory" "git config core.pager cat" 2 "rule:allowlist"
bt_rule "anthory git -C denied" "anthory" "git -C /tmp status" 2 "rule:allowlist"
bt_rule "anthory rm still denied" "anthory" "rm -rf /tmp/x" 2 "rule:deny-destructive"
bt_rule "anthory cp still denied" "anthory" "cp x hooks/y" 2 "rule:allowlist"
bt "anthory git checkout -b allow" "anthory" "git checkout -b feat/x" 0
bt_rule "anthory git switch -c denied (use checkout -b)" "anthory" "git switch -c feat/x" 2 "rule:allowlist"

# --- Bash authority is derived from the declared tool set (ADR 0002) ---
# A mutator flag does not grant Bash by itself: a synthetic mutator whose tool set
# has no Bash is denied by rule:no-bash-tool. This replaces the retired _xixi
# "sandbox mutator never holds Bash" assertions with the property that made them
# meaningful.
bt_rule "mutator without a Bash tool is blocked" "probe-mutator" "git status" 2 "rule:no-bash-tool"

# --- e2e-runner: multi-line fail-closed (F2-1) ---
bt "e2e multi-line block" "e2e-runner" $'playwright test\npython3 /tmp/x.py' 2

# --- e2e-runner: safe Playwright allowlist (F2-2) ---
bt "e2e local playwright test allow" "e2e-runner" "playwright test" 0 "BASE_URL=http://localhost:3000"
bt "e2e .bin/playwright test allow" "e2e-runner" "node_modules/.bin/playwright test" 0 "BASE_URL=http://localhost:3000"
bt "e2e npx --no-install playwright test allow" "e2e-runner" "npx --no-install playwright test" 0 "BASE_URL=http://localhost:3000"
bt "e2e playwright test without attested base URL block" "e2e-runner" "playwright test" 2
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
mint_approval with-deps
bt "e2e invalid install launcher cannot consume approval" "e2e-runner" "python3 /tmp/x.py playwright install --with-deps" 2
bt "e2e with-deps allow (approval file)" "e2e-runner" "npx --no-install playwright install --with-deps" 0
bt "e2e with-deps consumed (one-shot)" "e2e-runner" "npx --no-install playwright install --with-deps" 2
bt "e2e update-snapshots block (no approval)" "e2e-runner" "playwright test --update-snapshots" 2
mint_approval snapshots
bt "e2e invalid snapshot launcher cannot consume approval" "e2e-runner" "python3 /tmp/x.py playwright test --update-snapshots" 2
bt "e2e update-snapshots allow (approval file)" "e2e-runner" "playwright test --update-snapshots" 0 "BASE_URL=http://localhost:3000"
mint_approval snapshots
touch -t 202001010000 "$TMPD/approvals/snapshots"
bt_rule "e2e update-snapshots stale approval block" "e2e-runner" "playwright test --update-snapshots" 2 "needs orchestrator approval file" "BASE_URL=http://localhost:3000"
mint_approval snapshots
bt_rule "e2e -u cannot borrow approval (block)" "e2e-runner" "python3 -u /tmp/x.py" 2 "rule:" "BASE_URL=http://localhost:3000"

# Correctly bound but world-readable: this must fail on the MODE, not on the binding,
# or the test stops covering the permission check.
mint_approval snapshots
chmod 644 "$TMPD/approvals/snapshots"
bt_rule "e2e approval mode must be 600" "e2e-runner" "playwright test --update-snapshots" 2 "needs orchestrator approval file" "BASE_URL=http://localhost:3000"

# Two concurrent consumers race for one token; exactly one can atomically claim it.
mint_approval snapshots
race_payload=$(jq -nc --arg s "$TEST_SESSION" '{session_id:$s,agent_type:"e2e-runner",tool_input:{command:"playwright test --update-snapshots"}}')
# Keep the test driver in the foreground; both children are joined before return.
"${HOOK_ENV[@]}" BASE_URL=http://localhost:3000 python3 - "$TEST_CWD" "$BASH_HOOK" "$race_payload" "$TMPD" <<'RACE'
import pathlib, subprocess, sys
cwd, hook, payload, root = sys.argv[1:]
children = [subprocess.Popen(["bash", hook], cwd=cwd, stdin=subprocess.PIPE,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(2)]
for child in children:
    child.stdin.write(payload.encode())
    child.stdin.close()
for index, child in enumerate(children, 1):
    pathlib.Path(root, f"race{index}").write_text(str(child.wait()) + "\n")
RACE
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

# H1: indirect / multiline baseURL must fail closed (not only same-line literals).
# URL and baseURL key MUST be on different lines — same-line grep is the bug.
cat > "$TEST_CWD/indirect.conf.ts" <<'EOF'
const target = process.env.X || 'https://prod.example.com'
export default { use: { baseURL: target } }
EOF
bt "e2e --config indirect baseURL assignment block" "e2e-runner" "playwright test --config indirect.conf.ts" 2
cat > "$TEST_CWD/multiline.conf.ts" <<'EOF'
export default {
  use: {
    baseURL:
      'https://prod.example.com',
  },
}
EOF
bt "e2e --config multiline baseURL block" "e2e-runner" "playwright test --config multiline.conf.ts" 2
printf "%s\n" "const target = process.env.BASE_URL; export default { use: { baseURL: target } }" > "$TEST_CWD/unresolved.conf.ts"
bt "e2e --config unresolved baseURL block" "e2e-runner" "playwright test --config unresolved.conf.ts" 2
printf "%s\n" "// see https://playwright.dev" $'\n'"export default { use: { baseURL: 'http://localhost:3000' } }" > "$TEST_CWD/local-with-comment.conf.ts"
bt "e2e --config localhost baseURL with docs URL comment allow" "e2e-runner" "playwright test --config local-with-comment.conf.ts" 0 "BASE_URL=http://localhost:3000"

# H2: --base-url present but empty / valueless must not skip host checks.
bt "e2e empty --base-url= block" "e2e-runner" "playwright test --base-url=" 2
bt "e2e bare --base-url flag block" "e2e-runner" "playwright test --base-url" 2
bt "e2e IPv6 loopback --base-url allow" "e2e-runner" "playwright test --base-url=http://[::1]:3000" 0

printf "%s\n" "export default { use: { baseURL: 'https://prod.example.com' } }" > "$TEST_CWD/playwright.config.ts"
bt "e2e localhost BASE_URL with cwd prod playwright.config.ts block" "e2e-runner" "playwright test" 2 "BASE_URL=http://localhost:3000"
bt "e2e localhost --base-url with cwd prod playwright.config.ts block" "e2e-runner" "playwright test --base-url=http://localhost:3000" 2
rm -f "$TEST_CWD/playwright.config.ts"

# codegen output redirection blocking + quoted/escaped flag support
bt "e2e codegen --output block" "e2e-runner" "playwright codegen --output=hooks/restrict-bash-by-agent.sh http://localhost:3000" 2 "BASE_URL=http://localhost:3000"
bt "e2e codegen -o block" "e2e-runner" "playwright codegen -o hooks/restrict-bash-by-agent.sh http://localhost:3000" 2 "BASE_URL=http://localhost:3000"
bt "e2e codegen quoted option block" "e2e-runner" 'playwright codegen --out"put"=hooks/restrict-bash-by-agent.sh http://localhost:3000' 2 "BASE_URL=http://localhost:3000"
bt "e2e codegen backslash-escaped option block" "e2e-runner" 'playwright codegen --out\put=hooks/restrict-bash-by-agent.sh http://localhost:3000' 2 "BASE_URL=http://localhost:3000"
bt "e2e codegen allow without output option" "e2e-runner" "playwright codegen http://localhost:3000" 0 "BASE_URL=http://localhost:3000"
bt "e2e double-quoted base-url allow" "e2e-runner" 'playwright test --base-url="http://localhost:3000"' 0
bt "e2e single-quoted base-url allow" "e2e-runner" "playwright test --base-url='http://localhost:3000'" 0

# --- malformed payload → fail closed (only when agent_type names a gated agent) ---
out="$(printf '%s' '{"agent_type":"e2e-runner","tool_input":{' | "${HOOK_ENV[@]}" AGENT_CONTRACT_FILE="$AGENT_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" bash "$BASH_HOOK" 2>&1)"
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
hooks = [
    x
    for h in d['hooks']['PreToolUse']
    if h.get('matcher') == 'Bash'
    for x in h.get('hooks', [])
    if 'restrict-bash-by-agent.sh' in x.get('command', '')
]
sys.exit(0 if len(hooks) == 1 and hooks[0].get('timeout') == 5 else 1)
PY
  then
    PASS=$((PASS + 1)); echo "PASS  settings.json registers restrict-bash hook with timeout 5"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  settings.json does not register restrict-bash hook"
  fi
else
  FAIL=$((FAIL + 1)); echo "FAIL  settings registration check unavailable (SETTINGS=$SETTINGS, python3 required)"
fi

if grep -Eq '^[0-9]+ agent_type=e2e-runner rule=allowlist decision=allow$' "$HOOK_AUDIT_LOG" \
   && grep -Eq '^[0-9]+ agent_type=mark rule=review-only decision=deny$' "$HOOK_AUDIT_LOG"; then
  PASS=$((PASS + 1)); echo "PASS  hook audit logs timestamp, agent_type, rule, and decision"
else
  FAIL=$((FAIL + 1)); echo "FAIL  hook audit log missing allow/deny decision lines"
fi

# --- H3: mutator Write/Edit self-protection ---
wt() {
  local desc="$1" agent="$2" path="$3" exp="$4" cwd="${5:-$TEST_CWD}" rc payload out
  if [[ ! -x "$WRITE_HOOK" ]]; then
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (write hook missing)"
    return
  fi
  if [[ -n "$agent" ]]; then
    payload=$(jq -nc --arg a "$agent" --arg p "$path" --arg c "$cwd" '{agent_type:$a, cwd:$c, tool_input:{file_path:$p}}')
  else
    payload=$(jq -nc --arg p "$path" --arg c "$cwd" '{cwd:$c, tool_input:{file_path:$p}}')
  fi
  out="$(printf '%s' "$payload" | "${HOOK_ENV[@]}" HOOK_LIB_DIR="$FLEET_FAKE/hooks/lib" bash "$WRITE_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp" ]; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp) :: $(printf '%s' "$out" | head -1)"
  fi
}

wt "e2e-runner cannot rewrite bash gate" "e2e-runner" "$FLEET_FAKE/hooks/restrict-bash-by-agent.sh" 2
wt "e2e-runner cannot rewrite agent contract" "e2e-runner" "$FLEET_FAKE/tests/fixtures/agent-contract.tsv" 2
wt "e2e-runner cannot rewrite live settings" "e2e-runner" "$TEST_HOME/.claude/settings.json" 2
wt "e2e-runner cannot write approvals" "e2e-runner" "$FLEET_FAKE/hooks/approvals/with-deps" 2
wt "e2e-runner cannot rewrite clipboard script" "e2e-runner" "$FLEET_FAKE/scripts/copy-prompt.sh" 2
wt "e2e-runner cannot rewrite agent prompt file" "e2e-runner" "$FLEET_FAKE/architect.md" 2
wt "e2e-runner cannot rewrite live claude hooks" "e2e-runner" "$TEST_HOME/.claude/hooks/strategic-compact/suggest-compact.sh" 2
wt "e2e-runner cannot rewrite live claude scripts" "e2e-runner" "$TEST_HOME/.claude/scripts/otty-wrapper.sh" 2
wt "e2e-runner cannot rewrite settings.local.json" "e2e-runner" "$TEST_HOME/.claude/settings.local.json" 2
wt "e2e-runner relative fleet hook path blocked" "e2e-runner" "hooks/restrict-bash-by-agent.sh" 2 "$FLEET_FAKE"
wt "e2e-runner .. into fleet hooks blocked" "e2e-runner" "../hooks/restrict-bash-by-agent.sh" 2 "$FLEET_FAKE/tests"
if [[ "$(uname -s)" == Darwin ]]; then
  wt "e2e-runner cannot rewrite bash gate mixed-case path" "e2e-runner" "$FLEET_FAKE/Hooks/restrict-bash-by-agent.sh" 2
  wt "e2e-runner cannot rewrite mixed-case settings" "e2e-runner" "$TEST_HOME/.CLAUDE/settings.json" 2
fi
wt "main session can edit bash gate" "" "$FLEET_FAKE/hooks/restrict-bash-by-agent.sh" 0
wt "main session cannot write approvals" "" "$FLEET_FAKE/hooks/approvals/with-deps" 2
wt "e2e-runner can write product-repo tests" "e2e-runner" "tests/e2e/checkout.spec.ts" 0 "/tmp/other-app"

payload=$(jq -nc --arg a "e2e-runner" --arg p "$FLEET_FAKE/hooks/restrict-bash-by-agent.sh" --arg c "$TEST_CWD" '{agent_type:$a, cwd:$c, tool_input:{path:$p}}')
out="$(printf '%s' "$payload" | "${HOOK_ENV[@]}" HOOK_LIB_DIR="$FLEET_FAKE/hooks/lib" bash "$WRITE_HOOK" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ]; then
  PASS=$((PASS + 1)); echo "PASS  e2e-runner tool_input.path cannot rewrite bash gate"
else
  FAIL=$((FAIL + 1)); echo "FAIL  e2e-runner tool_input.path cannot rewrite bash gate (exit=$rc, want=2) :: $(printf '%s' "$out" | head -1)"
fi

# Grok PreToolUse is camelCase. Snake_case cases above stay the Claude contract.
# Absent identity stays main-session. A blank or non-object snake_case field must
# not hide subagentType / toolInput.
wt_payload() {
  local desc="$1" payload="$2" exp="$3" rc out
  out="$(printf '%s' "$payload" | "${HOOK_ENV[@]}" HOOK_LIB_DIR="$FLEET_FAKE/hooks/lib" bash "$WRITE_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp" ]; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp) :: $(printf '%s' "$out" | head -1)"
  fi
}

bt_payload "grok camelCase e2e-runner git status allowed" \
  "$(jq -nc '{subagentType:"e2e-runner", sessionId:"grok-session", toolInput:{command:"git status"}}')" 0
bt_payload "grok camelCase e2e-runner rm denied" \
  "$(jq -nc '{subagentType:"e2e-runner", toolInput:{command:"rm -rf /tmp/x"}}')" 2
bt_payload "grok camelCase mark bash denied" \
  "$(jq -nc '{subagentType:"mark", toolInput:{command:"git status"}}')" 2
bt_payload "grok camelCase without identity passes as main session" \
  "$(jq -nc '{toolInput:{command:"rm -rf /tmp/x"}}')" 0
bt_payload "boolean tool_input does not hide camelCase command" \
  "$(jq -nc '{tool_input:true, subagentType:"mark", toolInput:{command:"git status"}}')" 2
bt_payload "blank agent_type does not hide subagentType" \
  "$(jq -nc '{agent_type:"", subagentType:"mark", toolInput:{command:"ls"}}')" 2
bt_payload "conflicting identity fields denied" \
  "$(jq -nc '{agent_type:"e2e-runner", subagentType:"code-reviewer", tool_input:{command:"ls"}}')" 2
bt_payload "conflicting command fields denied" \
  "$(jq -nc '{agent_type:"e2e-runner", tool_input:{command:"git status"}, toolInput:{command:"rm -rf /tmp/x"}}')" 2
mint_approval snapshots
bt_payload "grok camelCase sessionId consumes a bound approval" \
  "$(jq -nc --arg s "$TEST_SESSION" '{sessionId:$s, subagentType:"e2e-runner", toolInput:{command:"playwright test --update-snapshots"}}')" \
  0 "BASE_URL=http://localhost:3000"

wt_payload "grok camelCase e2e-runner cannot rewrite bash gate" \
  "$(jq -nc --arg p "$FLEET_FAKE/hooks/restrict-bash-by-agent.sh" --arg c "$TEST_CWD" \
      '{subagentType:"e2e-runner", cwd:$c, toolInput:{file_path:$p}}')" 2
wt_payload "grok camelCase without identity can edit bash gate" \
  "$(jq -nc --arg p "$FLEET_FAKE/hooks/restrict-bash-by-agent.sh" --arg c "$TEST_CWD" \
      '{cwd:$c, toolInput:{file_path:$p}}')" 0
wt_payload "attributed write missing path denied" \
  "$(jq -nc '{agent_type:"e2e-runner", tool_input:{}}')" 2
wt_payload "main session missing path allowed" \
  "$(jq -nc '{tool_input:{}}')" 0
wt_payload "boolean tool_input does not hide protected toolInput path" \
  "$(jq -nc --arg p "$FLEET_FAKE/hooks/restrict-bash-by-agent.sh" \
      '{tool_input:true, subagentType:"e2e-runner", toolInput:{file_path:$p}}')" 2
wt_payload "conflicting write paths denied" \
  "$(jq -nc --arg safe "/tmp/other-app/ok.txt" --arg bad "$FLEET_FAKE/hooks/restrict-bash-by-agent.sh" \
      '{agent_type:"e2e-runner", tool_input:{file_path:$safe}, toolInput:{file_path:$bad}}')" 2

NOJQ="$TMPD/write-nojq"
mkdir -p "$NOJQ"
for b in bash sh grep sed awk tr cat env head cut uname dirname basename python3 mktemp rm date; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$NOJQ/$b"
done
# C14: ~/.grok/skills is a symlink. normpath-before-realpath turns
# skills/temu-copywriter/../../.claude/settings.json into ~/.grok/.claude/settings.json
# and misses the real settings file. realpath on the raw path must deny it.
SKILL_REAL="$TEST_HOME/skills/temu-copywriter"
AGENTS_SKILLS="$TEST_HOME/.agents/skills"
mkdir -p "$SKILL_REAL" "$AGENTS_SKILLS" "$TEST_HOME/.grok"
ln -s "$SKILL_REAL" "$AGENTS_SKILLS/temu-copywriter"
ln -s "$AGENTS_SKILLS" "$TEST_HOME/.grok/skills"
wt "e2e-runner symlink .. into live settings is denied" "e2e-runner" \
  "$TEST_HOME/.grok/skills/temu-copywriter/../../.claude/settings.json" 2
# The case above sits inside ~/.grok, so the whole-tree rule denies it even if
# normpath runs before realpath. This alias is outside every protected prefix;
# only physical resolution reaches live settings.
mkdir -p "$TEST_HOME/.claude/hooks" "$TEST_HOME/jump"
ln -s "$TEST_HOME/.claude/hooks" "$TEST_HOME/jump/link"
wt "symlink outside protected prefixes still resolves into live settings" "e2e-runner" \
  "$TEST_HOME/jump/link/../../.claude/settings.json" 2
mkdir -p "$TEST_HOME/.grok/hooks"
wt "e2e-runner cannot write grok config.toml" "e2e-runner" "$TEST_HOME/.grok/config.toml" 2
wt "e2e-runner cannot write grok hooks" "e2e-runner" "$TEST_HOME/.grok/hooks/agent-gates.json" 2
wt "main session can edit grok config.toml" "" "$TEST_HOME/.grok/config.toml" 0
wt "main session can edit grok hooks" "" "$TEST_HOME/.grok/hooks/agent-gates.json" 0
nl_path="${TEST_HOME}/.grok/foo"$'\n'"bar"
wt_payload "newline inside .grok is denied" \
  "$(jq -nc --arg p "$nl_path" '{agent_type:"e2e-runner", tool_input:{file_path:$p}}')" 2
wt_payload "non-string agent_type cannot edit the bash gate" \
  "$(jq -nc --arg p "$FLEET_FAKE/hooks/restrict-bash-by-agent.sh" '{agent_type:17, tool_input:{file_path:$p}}')" 2
wt_payload "concatenated JSON is denied" \
  "$(printf '%s%s' \
      "$(jq -nc '{agent_type:"e2e-runner", tool_input:{file_path:"/tmp/ok.txt"}}')" \
      "$(jq -nc --arg p "$FLEET_FAKE/hooks/restrict-bash-by-agent.sh" '{agent_type:"e2e-runner", tool_input:{file_path:$p}}')")" 2

NOPY="$TMPD/write-nopy"
mkdir -p "$NOPY"
for b in bash sh grep sed awk tr cat env head cut uname dirname basename jq mktemp rm date; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$NOPY/$b"
done
if [ -e "$NOPY/python3" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL  write no-python PATH stub still contains python3"
else
  out="$(printf '%s' "$(jq -nc --arg p "/tmp/other-app/ok.txt" '{agent_type:"e2e-runner", tool_input:{file_path:$p}}')" | env -i PATH="$NOPY" HOME="$TEST_HOME" TMPDIR="$TMPD" CLAUDE_CONFIG_DIR="$TEST_CONFIG" HOOK_LIB_DIR="$FLEET_FAKE/hooks/lib" bash "$WRITE_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'rule:realpath'; then
    PASS=$((PASS + 1)); echo "PASS  attributed write without python3 is denied"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  attributed write without python3 (exit=$rc, want=2) :: $(printf '%s' "$out" | head -1)"
  fi
  out="$(printf '%s' "$(jq -nc --arg p "/tmp/other-app/ok.txt" '{tool_input:{file_path:$p}}')" | env -i PATH="$NOPY" HOME="$TEST_HOME" TMPDIR="$TMPD" CLAUDE_CONFIG_DIR="$TEST_CONFIG" HOOK_LIB_DIR="$FLEET_FAKE/hooks/lib" bash "$WRITE_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "PASS  main session write without python3 still allowed"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  main session write without python3 (exit=$rc, want=0) :: $(printf '%s' "$out" | head -1)"
  fi
fi

if [ -e "$NOJQ/jq" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL  write no-jq PATH stub still contains jq"
else
  out="$(printf '%s' '{"subagentType":"e2e-runner","toolInput":{"file_path":"/tmp/x"}}' | env -i PATH="$NOJQ" HOME="$TEST_HOME" TMPDIR="$TMPD" CLAUDE_CONFIG_DIR="$TEST_CONFIG" HOOK_LIB_DIR="$FLEET_FAKE/hooks/lib" bash "$WRITE_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'jq unavailable'; then
    PASS=$((PASS + 1)); echo "PASS  write hook no-jq camelCase subagentType fails closed"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  write hook no-jq camelCase subagentType (exit=$rc, want=2) :: $(printf '%s' "$out" | head -1)"
  fi
  out="$(printf '%s' "{\"tool_input\":{\"file_path\":\"$FLEET_FAKE/hooks/approvals/with-deps\"}}" | env -i PATH="$NOJQ" HOME="$TEST_HOME" TMPDIR="$TMPD" CLAUDE_CONFIG_DIR="$TEST_CONFIG" HOOK_LIB_DIR="$FLEET_FAKE/hooks/lib" bash "$WRITE_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'jq unavailable'; then
    PASS=$((PASS + 1)); echo "PASS  write hook no-jq unattributed approvals denied"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  write hook no-jq unattributed approvals (exit=$rc, want=2) :: $(printf '%s' "$out" | head -1)"
  fi
  out="$(printf '%s' '{"tool_input":{"file_path":"/tmp/ordinary.txt"}}' | env -i PATH="$NOJQ" HOME="$TEST_HOME" TMPDIR="$TMPD" CLAUDE_CONFIG_DIR="$TEST_CONFIG" HOOK_LIB_DIR="$FLEET_FAKE/hooks/lib" bash "$WRITE_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'jq unavailable'; then
    PASS=$((PASS + 1)); echo "PASS  write hook no-jq unattributed ordinary path denied"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  write hook no-jq unattributed ordinary path (exit=$rc, want=2) :: $(printf '%s' "$out" | head -1)"
  fi
fi

if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1 && python3 -c 'import json' 2>/dev/null; then
  if python3 - "$SETTINGS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hooks = [
    x
    for h in d.get("hooks", {}).get("PreToolUse", [])
    if h.get("matcher") == "Write|Edit"
    for x in h.get("hooks", [])
    if "restrict-mutator-write.sh" in x.get("command", "")
]
sys.exit(0 if len(hooks) == 1 and hooks[0].get("timeout") == 5 else 1)
PY
  then
    PASS=$((PASS + 1)); echo "PASS  settings.json registers restrict-mutator-write hook with timeout 5"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  settings.json does not register restrict-mutator-write hook"
  fi
fi

# --- live fleet policy matrix (7 roles; ADR 0005 + ADR 0006) ------------------
# These run against the LIVE contract, not the gate contract, and assert the real
# decision per identity: review-only roles have no Bash, executor roles have the
# execution-only allowlist. "No agent may hold Bash" is no longer the invariant.

lt_rule() {
  local desc="$1" agent="$2" cmd="$3" exp="$4" want_rule="$5" dir="$6" rc payload out
  shift 6
  payload=$(jq -nc --arg a "$agent" --arg c "$cmd" '{agent_type:$a, tool_input:{command:$c}}')
  out="$(cd "$dir" && printf '%s' "$payload" | "${HOOK_ENV[@]}" AGENT_CONTRACT_FILE="$LIVE_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" "$@" bash "$BASH_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp" ] && { [ -z "$want_rule" ] || printf '%s' "$out" | grep -q -- "$want_rule"; }; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp, rule '$want_rule') :: $(printf '%s' "$out" | tr '\n' ' | ')"
  fi
}

echo "==> live fleet policy matrix (7 roles)"
for a in mark octavion atia; do
  lt_rule "live: $a (review_only) denied inside the fleet" "$a" "git status" 2 "rule:review-only" "$TMPD"
  lt_rule "live: $a (review_only) denied outside the fleet" "$a" "git status" 2 "rule:review-only" "$TEST_CWD"
done
lt_rule "live: anthory (orchestrator) git status allowed" "anthory" "git status" 0 "" "$TEST_CWD"
lt_rule "live: anthory (orchestrator) git push allowed" "anthory" "git push origin main" 0 "" "$TEST_CWD"
lt_rule "live: anthory (orchestrator) non-git write denied" "anthory" "cp x hooks/y" 2 "rule:allowlist" "$TEST_CWD"
for a in vorenus pullo posca; do
  lt_rule "live: $a (executor) git status allowed" "$a" "git status" 0 "" "$TEST_CWD"
  lt_rule "live: $a (executor) write command denied" "$a" "cp x hooks/y" 2 "rule:allowlist" "$TEST_CWD"
done
# The fleet-script row must run the REAL hook: a copy under $TMPD has a different
# fleet root and would reject the real repo's tests/ path. Asserted below via xt.

# Main session must stay unaffected by the fleet policy gate.
for payload in '{"tool_input":{"command":"git status"}}' '{"tool_input":{"command":"cp x hooks/y"}}'; do
  if printf '%s' "$payload" | "${HOOK_ENV[@]}" AGENT_CONTRACT_FILE="$LIVE_CONTRACT_FILE" HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" bash "$BASH_HOOK" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "PASS  live contract: main session (no agent_type) unaffected"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  live contract: fleet policy leaked onto the main session"
  fi
done
# An identity with no definition and no row is external; the gate abstains (ADR 0005).
lt_rule "live: unknown external identity passes through" "stranger" "git status" 0 "" "$TEST_CWD"

# --- executor allow/deny matrix (real hook path + live contract) ----------------
# The real hook derives ${FLEET_ROOT} from its own location, so a script path under
# the real fleet's tests/ resolves inside it. Running a copy from $TMPD would reject
# `bash $REPO_ROOT/tests/run_all.sh` because that canonical path would be outside
# the copy's fleet root — not the property under test here.
xt() {
  local desc="$1" agent="$2" cmd="$3" exp="$4" want_rule="$5" rc payload out
  shift 5
  payload=$(jq -nc --arg a "$agent" --arg c "$cmd" '{agent_type:$a, tool_input:{command:$c}}')
  out="$(cd "$TEST_CWD" && printf '%s' "$payload" | env -i PATH="$PATH" HOME="$TEST_HOME" \
    TMPDIR="$TMPD" CLAUDE_CONFIG_DIR="$TEST_CONFIG" HOOK_LIB_DIR="$REPO_ROOT/hooks/lib" \
    APPROVAL_DIR="$TMPD/approvals" AGENT_CONTRACT_FILE="$LIVE_CONTRACT_FILE" \
    HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" "$@" bash "$HOOK_SRC" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp" ] && { [ -z "$want_rule" ] || printf '%s' "$out" | grep -q -- "$want_rule"; }; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp, rule '$want_rule') :: $(printf '%s' "$out" | tr '\n' ' | ')"
  fi
}

echo "==> executor allowlist: allowed commands"
for cmd in \
  "git status" \
  "git diff --stat" \
  "ls -la" \
  "cat README.md" \
  "grep -n x README.md" \
  "bash $REPO_ROOT/tests/run_all.sh" \
  "bash $REPO_ROOT/tests/guardrails.sh --strict" \
  "pytest" \
  "pytest tests/" \
  "pytest -q tests/test_x.py" \
  "python3 -m pytest -q" \
  "python3 -m unittest" \
  "python3 -m unittest -v" \
  "python3 -m unittest -s tests" \
  "python3 -m unittest discover -s tests -p 'test_*.py'" \
  "python3 -m unittest tests.test_foo" \
  "python3 -m json.tool package.json" \
  "go test ./..." \
  "cargo test" \
  "make test" \
  "npm test" \
  "npm run lint"
do
  xt "executor allows: $cmd" vorenus "$cmd" 0 ""
done
for a in vorenus pullo posca anthory; do
  xt "live: $a (executor) fleet test script allowed" "$a" "bash $REPO_ROOT/tests/run_all.sh" 0 ""
done

echo "==> executor allowlist: denied commands"
# Each row carries the rule that must fire. Commands rejected by an earlier layer
# (tokenizer, destructive/escape/install deny) keep that layer's rule: asserting a
# single rule:allowlist for all of them would either be false or force the executor
# library to re-detect what the global deny rules already handle.
xt_deny() { xt "$1" vorenus "$2" 2 "$3"; }
xt_deny "executor denies cp"                 "cp x hooks/y" allowlist
xt_deny "executor denies mv"                 "mv x tests/y" allowlist
xt_deny "executor denies sed -i"             "sed -i s/a/b hooks/x" allowlist
xt_deny "executor denies tee"                "tee hooks/x" allowlist
xt_deny "executor denies truncate"           "truncate -s0 tests/x" allowlist
xt_deny "executor denies ln"                 "ln -s x hooks/y" allowlist
xt_deny "executor denies git checkout"       "git checkout -- hooks/x" allowlist
xt_deny "executor denies git restore"        "git restore hooks/x" allowlist
xt_deny "executor denies git apply"          "git apply p.diff" allowlist
xt_deny "executor denies git add"            "git add ." allowlist
xt_deny "executor denies git commit"         "git commit -m x" allowlist
xt_deny "executor denies git push"           "git push" deny-destructive
xt_deny "executor denies git reset"          "git reset --hard" deny-destructive
xt_deny "executor denies /tmp script"        "bash /tmp/x.sh" allowlist
xt_deny "executor denies scripts/create-approval.sh" "bash $REPO_ROOT/scripts/create-approval.sh snapshots s" allowlist
xt_deny "executor denies scripts/sync-codex-mirror.sh" "bash $REPO_ROOT/scripts/sync-codex-mirror.sh" allowlist
xt_deny "executor denies .. into hooks"      "bash $REPO_ROOT/tests/../hooks/restrict-bash-by-agent.sh" allowlist
xt_deny "executor denies bash -c"            "bash -c 'x'" deny-escape
xt_deny "executor denies python file"        "python3 /tmp/x.py" allowlist
xt_deny "executor denies python module"      "python3 -m http.server" allowlist
xt_deny "executor denies pip via python"     "python3 -m pip install x" allowlist
xt_deny "executor denies node file"          "node /tmp/x.js" allowlist
xt_deny "executor denies find -delete"       "find . -delete" allowlist
xt_deny "executor denies xargs"              "xargs rm" allowlist
xt_deny "executor denies curl"               "curl" deny-escape
xt_deny "executor denies npm install"        "npm install" deny-install
xt_deny "executor denies rm"                 "rm -rf" deny-destructive
xt_deny "executor denies redirect"           "echo a > hooks/x" no-shell-meta
xt_deny "executor denies &&"                 "a && b" no-shell-meta
xt_deny "executor denies ;"                  "a; b" no-shell-meta
xt_deny "executor denies absolute pytest"    "pytest /tmp/x.py" allowlist
xt_deny "executor denies .. pytest"          "pytest ../x.py" allowlist
xt_deny "executor denies unittest -s /tmp"   "python3 -m unittest -s /tmp" allowlist
xt_deny "executor denies unittest discover /tmp" "python3 -m unittest discover -s /tmp" allowlist
xt_deny "executor denies make -f"            "make -f /tmp/Makefile test" allowlist
xt_deny "executor denies make --directory"   "make --directory /tmp test" allowlist
xt_deny "executor denies make --eval shell meta" "make --eval 'x:;rm -rf y' test" no-shell-meta
xt_deny "executor denies go -exec"           "go test -exec /tmp/x" allowlist
xt_deny "executor denies go -toolexec"       "go test -toolexec /tmp/x" allowlist
xt_deny "executor denies go -overlay"        "go test -overlay /tmp/o.json" allowlist
xt_deny "executor denies git -c"             "git -c core.pager=evil diff" allowlist
xt_deny "executor denies git --config-env"   "git --config-env=a=b status" allowlist
xt_deny "executor denies git --exec-path"    "git --exec-path=/tmp status" allowlist
xt_deny "executor denies git --git-dir"      "git --git-dir=/tmp/x status" allowlist
xt_deny "executor denies git --work-tree"    "git --work-tree=/tmp status" allowlist
xt_deny "executor denies git -C"             "git -C /tmp status" allowlist
xt_deny "executor denies git --paginate"     "git --paginate log" allowlist

# --- executor script boundary: canonical path must be this fleet's tests/ ------
FAKE_FLEET="$TMPD/fleet"
mkdir -p "$FAKE_FLEET/hooks/lib" "$FAKE_FLEET/tests" "$FAKE_FLEET/scripts" "$TMPD/tests"
cp "$HOOK_SRC" "$FAKE_FLEET/hooks/"
cp "$REPO_ROOT"/hooks/lib/*.sh "$FAKE_FLEET/hooks/lib/"
: > "$FAKE_FLEET/tests/run_all.sh"
: > "$TMPD/tests/run_all.sh"
: > "$FAKE_FLEET/scripts/create-approval.sh"
: > "$FAKE_FLEET/scripts/sync-codex-mirror.sh"
: > "$FAKE_FLEET/hooks/gate.sh"
ln -s "$FAKE_FLEET/hooks/gate.sh" "$FAKE_FLEET/tests/link.sh"
EXEC_CONTRACT="$TMPD/executor-contract.tsv"
cp "$LIVE_CONTRACT_FILE" "$EXEC_CONTRACT"

ft() {
  local desc="$1" cmd="$2" exp="$3" dir="$4" want_rule="$5" rc payload out
  payload=$(jq -nc --arg a "vorenus" --arg c "$cmd" '{agent_type:$a, tool_input:{command:$c}}')
  out="$(cd "$dir" && printf '%s' "$payload" | "${HOOK_ENV[@]}" \
    AGENT_CONTRACT_FILE="$EXEC_CONTRACT" HOOK_LIB_DIR="$FAKE_FLEET/hooks/lib" \
    HOOK_AUDIT_LOG="$HOOK_AUDIT_LOG" bash "$FAKE_FLEET/hooks/restrict-bash-by-agent.sh" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp" ] && { [ -z "$want_rule" ] || printf '%s' "$out" | grep -q -- "$want_rule"; }; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp, rule '$want_rule') :: $(printf '%s' "$out" | tr '\n' ' | ')"
  fi
}

echo "==> executor script boundary (fake fleet)"
ft "script: relative path inside fake fleet tests allowed" "bash tests/run_all.sh" 0 "$FAKE_FLEET" ""
ft "script: absolute fake fleet tests path allowed" "bash $FAKE_FLEET/tests/run_all.sh" 0 "$TEST_CWD" ""
ft "script: relative path resolving outside fake fleet tests denied" "bash tests/run_all.sh" 2 "$TMPD" "rule:allowlist"
ft "script: .. segment denied" "bash tests/../hooks/gate.sh" 2 "$FAKE_FLEET" "rule:allowlist"
ft "script: symlink into fake hooks denied" "bash tests/link.sh" 2 "$FAKE_FLEET" "rule:allowlist"
ft "script: fake scripts/create-approval.sh denied" "bash scripts/create-approval.sh snapshots s" 2 "$FAKE_FLEET" "rule:allowlist"
ft "script: fake scripts/sync-codex-mirror.sh denied" "bash scripts/sync-codex-mirror.sh" 2 "$FAKE_FLEET" "rule:allowlist"
ft "script: real fleet path outside fake fleet denied" "bash $REPO_ROOT/tests/run_all.sh" 2 "$TEST_CWD" "rule:allowlist"

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
