#!/usr/bin/env bash
#
# p1-bypass.test.sh — RED probes for the 2026-09-09 audit's remaining P1 findings.
#
# Each probe asserts the hook BLOCKS a payload that today it allows. A probe that
# passes means the bypass is closed; a probe that fails means the defect is live.
# Findings #4/#5/#6 are already closed by ADR 0002 and are covered in hooks.test.sh.
#
# Isolation: temporary copies of the hooks, a fixture fleet tree, a derived gate
# contract (ADR 0002 left no Bash-capable agent, so the parser needs one), and a
# temp CLAUDE_CONFIG_DIR. Nothing here touches the real ~/.claude or approvals.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASH_HOOK_SRC="${BASH_HOOK_SRC:-$REPO_ROOT/hooks/restrict-bash-by-agent.sh}"
WRITE_HOOK_SRC="${WRITE_HOOK_SRC:-$REPO_ROOT/hooks/restrict-mutator-write.sh}"
XIXI_HOOK_SRC="${XIXI_HOOK_SRC:-$REPO_ROOT/hooks/xixi/restrict-write.sh}"
LIVE_CONTRACT_FILE="${AGENT_CONTRACT_FILE:-$SCRIPT_DIR/fixtures/agent-contract.tsv}"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
TEST_CWD="$TMPD/cwd"; mkdir -p "$TEST_CWD"
APPROVAL_DIR="$TMPD/approvals"; mkdir -p "$APPROVAL_DIR"
FAKE_CLAUDE="$TMPD/claude-home"; mkdir -p "$FAKE_CLAUDE/rules" "$FAKE_CLAUDE/hooks"
: > "$FAKE_CLAUDE/rules/agents.md"

# Isolated fleet tree so restrict-mutator-write.sh derives FLEET_ROOT from its dirname.
FLEET="$TMPD/fleet"; mkdir -p "$FLEET/hooks/lib" "$FLEET/hooks/approvals" "$FLEET/.git" "$FLEET/.claude"
cp "$WRITE_HOOK_SRC" "$FLEET/hooks/restrict-mutator-write.sh"; chmod +x "$FLEET/hooks/restrict-mutator-write.sh"
[[ -d "$REPO_ROOT/hooks/lib" ]] && cp -R "$REPO_ROOT/hooks/lib/." "$FLEET/hooks/lib/"
WRITE_HOOK="$FLEET/hooks/restrict-mutator-write.sh"
: > "$FLEET/.git/config"; : > "$FLEET/.claude/settings.json"

BASH_HOOK="$TMPD/restrict-bash-by-agent.sh"
cp "$BASH_HOOK_SRC" "$BASH_HOOK"; chmod +x "$BASH_HOOK"
[[ -d "$REPO_ROOT/hooks/lib" ]] && cp -R "$REPO_ROOT/hooks/lib" "$TMPD/lib"

# ADR 0002 left no fleet agent holding Bash. The allowlist and its command parser
# still exist and are what these probes exercise, so grant e2e-runner Bash here.
GATE_CONTRACT="$TMPD/gate-contract.tsv"
awk -F'|' -v OFS='|' '$1=="e2e-runner"{$2="Read, Write, Edit, Bash, Grep, Glob"}1' \
  "$LIVE_CONTRACT_FILE" > "$GATE_CONTRACT"
grep -q '^e2e-runner|Read, Write, Edit, Bash, ' "$GATE_CONTRACT" || {
  echo "FATAL: could not derive gate contract" >&2; exit 2; }

AUDIT_LOG="$TMPD/audit.log"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

# probe_bash <id-desc> <command> [ENV=VAL ...]  — must exit 2
probe_bash() {
  local desc="$1" cmd="$2"; shift 2
  local payload rc out
  payload=$(jq -nc --arg c "$cmd" '{agent_type:"e2e-runner", tool_input:{command:$c}}')
  out="$(cd "$TEST_CWD" && printf '%s' "$payload" | env \
    AGENT_CONTRACT_FILE="$GATE_CONTRACT" APPROVAL_DIR="$APPROVAL_DIR" \
    HOOK_AUDIT_LOG="$AUDIT_LOG" "$@" bash "$BASH_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq 2 ]; then ok "$desc"
  else bad "$desc (exit=$rc, want=2) :: $(printf '%s' "$out" | tr '\n' ' | ')"; fi
}

# probe_raw <desc> <hook> <raw-payload> <want-exit> [ENV=VAL ...]
probe_raw() {
  local desc="$1" hook="$2" payload="$3" want="$4"; shift 4
  local rc out
  out="$(cd "$TEST_CWD" && printf '%s' "$payload" | env \
    AGENT_CONTRACT_FILE="$GATE_CONTRACT" APPROVAL_DIR="$APPROVAL_DIR" \
    HOOK_AUDIT_LOG="$AUDIT_LOG" "$@" bash "$hook" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$desc"
  else bad "$desc (exit=$rc, want=$want) :: $(printf '%s' "$out" | tr '\n' ' | ')"; fi
}

# probe_write <desc> <file_path> <agent-json-fragment> — must exit 2
probe_write() {
  local desc="$1" fp="$2" agent="$3"; shift 3
  local payload rc out
  if [ -n "$agent" ]; then
    payload=$(jq -nc --arg a "$agent" --arg f "$fp" '{agent_type:$a, tool_input:{file_path:$f}}')
  else
    payload=$(jq -nc --arg f "$fp" '{tool_input:{file_path:$f}}')
  fi
  out="$(cd "$TEST_CWD" && printf '%s' "$payload" | env \
    CLAUDE_CONFIG_DIR="$FAKE_CLAUDE" APPROVAL_DIR="$APPROVAL_DIR" \
    HOOK_AUDIT_LOG="$AUDIT_LOG" "$@" bash "$WRITE_HOOK" 2>&1)"
  rc=$?
  if [ "$rc" -eq 2 ]; then ok "$desc"
  else bad "$desc (exit=$rc, want=2) :: $(printf '%s' "$out" | tr '\n' ' | ')"; fi
}

echo "==> P1 bypass probes (RED until the hooks are fixed)"

# --- #1 snapshot approval bypass via shell quoting -----------------------------
# The approval branch reads the quote-intact string; the shell would pass
# --update-snapshots through. No approval token exists in APPROVAL_DIR.
probe_bash '#1 approval bypass: --update-"snapshots"' \
  'playwright test --update-"snapshots"' BASE_URL=http://localhost:3000
probe_bash "#1 approval bypass: --update-'snapshots'" \
  "playwright test --update-'snapshots'" BASE_URL=http://localhost:3000
probe_bash '#1 approval bypass: --update-snap\shots' \
  'playwright test --update-snap\shots' BASE_URL=http://localhost:3000

# --- #2 git separated --output --------------------------------------------------
probe_bash '#2 git separated --output' "git diff --output $TMPD/p1-git-out"
probe_bash '#2 git show separated --output' "git show --output $TMPD/p1-git-out2"

# --- #3 codegen attached/alternate output options -------------------------------
probe_bash '#3 codegen attached -o' \
  "playwright codegen -o$TMPD/p1-cg http://localhost:3000" BASE_URL=http://localhost:3000
probe_bash '#3 codegen --save-har' \
  "playwright codegen --save-har=$TMPD/p1.har http://localhost:3000" BASE_URL=http://localhost:3000
probe_bash '#3 codegen --save-storage' \
  "playwright codegen --save-storage=$TMPD/p1.json http://localhost:3000" BASE_URL=http://localhost:3000

# --- #10 unvalidated config via -c ----------------------------------------------
printf 'export default { use: { baseURL: process.env.SOMETHING } };\n' > "$TMPD/uninspected.ts"
probe_bash '#10 -c skips config validation' \
  "playwright test -c $TMPD/uninspected.ts" BASE_URL=http://localhost:3000

# --- #11 baseURL regex satisfied by an unresolved identifier --------------------
mkdir -p "$TEST_CWD"
cat > "$TEST_CWD/playwright.config.ts" <<'CFG'
const target = process.env.TARGET;
export default { use: { baseURL: target // http://localhost:3000
} };
CFG
# BASE_URL is supplied so rule:prod-guard passes; the block must come from the
# config's baseURL being an unresolved identifier, which the hook claims to reject.
probe_bash '#11 unresolved baseURL identifier + URL in comment' \
  'playwright test' BASE_URL=http://localhost:3000
rm -f "$TEST_CWD/playwright.config.ts"

# --- #9 schema confusion: valid JSON that is not an event object ----------------
probe_raw '#9 bash hook rejects []'            "$BASH_HOOK"  '[]' 2
probe_raw '#9 bash hook rejects "str"'         "$BASH_HOOK"  '"str"' 2
probe_raw '#9 write hook rejects []'           "$WRITE_HOOK" '[]' 2 CLAUDE_CONFIG_DIR="$FAKE_CLAUDE"

# --- #12 xixi write hook must DENY (exit 2), not error out ----------------------
if [ -f "$XIXI_HOOK_SRC" ]; then
  probe_raw '#12 xixi write hook denies [] with exit 2' "$XIXI_HOOK_SRC" '[]' 2
fi

# --- #8 attribution spoofing when jq is absent -----------------------------------
# A JSON-escaped key is valid JSON but defeats a literal "agent_type" regex.
NOJQ="$TMPD/nojq"; mkdir -p "$NOJQ"
for b in bash sh sed grep awk tr cat env head cut uname dirname basename \
         readlink python3 mktemp rm date id stat printf; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$NOJQ/$b"
done
[ -e "$NOJQ/jq" ] && { echo "FATAL: jq leaked into the no-jq PATH stub" >&2; exit 2; }
# A JSON-escaped key name is valid JSON, so jq would read it as agent_type, but a
# literal "agent_type" regex does not match it.
escaped='{"\u0061gent_type":"e2e-runner","tool_input":{"command":"rm -rf /tmp/p1-probe"}}'
out8="$(cd "$TEST_CWD" && printf '%s' "$escaped" | env -i PATH="$NOJQ" HOME="$TMPD" \
  AGENT_CONTRACT_FILE="$GATE_CONTRACT" APPROVAL_DIR="$APPROVAL_DIR" \
  HOOK_AUDIT_LOG="$AUDIT_LOG" bash "$BASH_HOOK" 2>&1)"
rc8=$?
if [ "$rc8" -eq 2 ]; then ok '#8 jq-absent: escaped agent_type key still attributed'
else bad "#8 jq-absent: escaped agent_type key treated as main session (exit=$rc8, want=2) :: $(printf '%s' "$out8" | tr '\n' ' | ')"; fi

# --- #7 self-protection gaps ------------------------------------------------------
probe_write '#7 rules/ is protected'                "$FAKE_CLAUDE/rules/agents.md"   e2e-runner
probe_write '#7 project .claude/settings.json'      "$FLEET/.claude/settings.json"   e2e-runner
probe_write '#7 .git/config is protected'           "$FLEET/.git/config"             e2e-runner

# --- #13 approvals protected even without attribution ---------------------------
# With python3 available, canonicalization succeeds and the approvals check works.
# The defect is that a normalization FAILURE only blocks when agent is non-empty,
# so the probe must remove python3 from PATH.
NOPY="$TMPD/nopy"; mkdir -p "$NOPY"
for b in bash sh sed grep awk tr cat env head cut uname dirname basename jq mktemp rm date; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$NOPY/$b"
done
[ -e "$NOPY/python3" ] && { echo "FATAL: python3 leaked into the no-python PATH stub" >&2; exit 2; }
payload13=$(jq -nc --arg f "$FLEET/hooks/lib/../approvals/with-deps" '{tool_input:{file_path:$f}}')
out13="$(cd "$TEST_CWD" && printf '%s' "$payload13" | env -i PATH="$NOPY" HOME="$TMPD" \
  CLAUDE_CONFIG_DIR="$FAKE_CLAUDE" APPROVAL_DIR="$APPROVAL_DIR" \
  HOOK_AUDIT_LOG="$AUDIT_LOG" bash "$WRITE_HOOK" 2>&1)"
rc13=$?
if [ "$rc13" -eq 2 ]; then ok '#13 unattributed traversal into approvals (no python3)'
else bad "#13 unattributed traversal into approvals reached exit=$rc13, want=2 :: $(printf '%s' "$out13" | tr '\n' ' | ')"; fi

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
