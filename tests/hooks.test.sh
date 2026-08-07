#!/usr/bin/env bash
#
# hooks.test.sh — regression for _xixi write gate + mutator bash gate (grill / audit-fix).
# HOOK_ROOT defaults to ~/.claude/agents/hooks (git-tracked). Override for CI.
#
set -uo pipefail

HOOK_ROOT="${HOOK_ROOT:-$HOME/.claude/agents/hooks}"
HOOK="$HOOK_ROOT/xixi/restrict-write.sh"
BASH_HOOK="$HOOK_ROOT/restrict-bash-by-agent.sh"
PASS=0
FAIL=0
ARTIFACTS=()

cleanup() {
  for p in "${ARTIFACTS[@]:-}"; do [ -e "$p" ] || [ -L "$p" ] && rm -f -- "$p" 2>/dev/null || true; done
  rm -f -- "$HOOK_ROOT/approvals/with-deps" "$HOOK_ROOT/approvals/snapshots" 2>/dev/null || true
}
trap cleanup EXIT

if [ ! -f "$HOOK" ]; then
  echo "FATAL: hook not found at $HOOK (set HOOK_ROOT)" >&2
  exit 2
fi

t() {
  local desc="$1" inp="$2" exp="$3" rc
  printf '%s' "$inp" | bash "$HOOK" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$exp" ]; then
    PASS=$((PASS + 1)); echo "PASS  $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp)"
  fi
}

RAND=$(python3 -c 'import secrets; print(secrets.token_hex(4))' 2>/dev/null || echo "a1b2c3d4")
ID1="${RAND:0:8}"
ID2="b${RAND:1:7}"
ID3="c${RAND:1:7}"
# ensure 8 alnum
ID1=$(printf '%s' "$ID1" | tr -cd 'A-Za-z0-9' | head -c 8)
while [ ${#ID1} -lt 8 ]; do ID1="${ID1}a"; done
ID2=$(printf '%s' "x${ID1:1:7}")
ID3=$(printf '%s' "y${ID1:1:7}")
ID4=$(printf '%s' "z${ID1:1:7}")

VALID="/tmp/xixi-prompt-$ID1"
SYM="/tmp/xixi-prompt-$ID2"
PRE="/tmp/xixi-prompt-$ID3"
ARTIFACTS+=("$VALID" "$SYM" "$PRE" "/tmp/xixi-prompt-$ID4")

echo "==> _xixi restrict-write.sh gate tests (HOOK_ROOT=$HOOK_ROOT)"

t "valid fresh path (_xixi)            -> allow" \
  '{"tool_input":{"file_path":"'"$VALID"'"},"agent_type":"_xixi"}' 0
# reserve may leave empty file
ARTIFACTS+=("$VALID")

t "non-_xixi agent, any path           -> allow" \
  '{"tool_input":{"file_path":"/etc/passwd"},"agent_type":"tdd-guide"}' 0
t "main session (no agent_type)        -> allow" \
  '{"tool_input":{"file_path":"/etc/anything"}}' 0

t "bad extension (.sh)                 -> block" \
  '{"tool_input":{"file_path":"/tmp/xixi-prompt-AbCdEfGh.sh"},"agent_type":"_xixi"}' 2
t "wrong directory (not /tmp)          -> block" \
  '{"tool_input":{"file_path":"/var/tmp/xixi-prompt-AbCdEfGh"},"agent_type":"_xixi"}' 2
t "id too short (7 chars)              -> block" \
  '{"tool_input":{"file_path":"/tmp/xixi-prompt-AbCdEf1"},"agent_type":"_xixi"}' 2
t "id too long (9 chars)               -> block" \
  '{"tool_input":{"file_path":"/tmp/xixi-prompt-AbCdEfGh9"},"agent_type":"_xixi"}' 2
t "fixed name (no id)                  -> block" \
  '{"tool_input":{"file_path":"/tmp/xixi-prompt"},"agent_type":"_xixi"}' 2
t ".. traversal                        -> block" \
  '{"tool_input":{"file_path":"/tmp/xixi-prompt-../etc/passwd"},"agent_type":"_xixi"}' 2

ln -sf "$HOME/.zshrc" "$SYM" 2>/dev/null || true
t "TOCTOU symlink -> ~/.zshrc          -> block" \
  '{"tool_input":{"file_path":"'"$SYM"'"},"agent_type":"_xixi"}' 2

printf 'stale\n' > "$PRE"
t "pre-existing regular file           -> block" \
  '{"tool_input":{"file_path":"'"$PRE"'"},"agent_type":"_xixi"}' 2

# ---------------------------------------------------------------------------
# restrict-bash-by-agent.sh
# ---------------------------------------------------------------------------
if [ -f "$BASH_HOOK" ]; then
  echo
  echo "==> restrict-bash-by-agent.sh gate tests"
  bt() {
    local desc="$1" agent="$2" cmd="$3" exp="$4" rc payload
    payload=$(jq -nc --arg a "$agent" --arg c "$cmd" '{agent_type:$a, tool_input:{command:$c}}')
    printf '%s' "$payload" | bash "$BASH_HOOK" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq "$exp" ]; then
      PASS=$((PASS + 1)); echo "PASS  $desc"
    else
      FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit=$rc, want=$exp)"
    fi
  }
  bt "main session free" "" "rm -rf /tmp/x" 0
  bt "build tsc allow" "build-error-resolver" "npx tsc --noEmit" 0
  bt "build npm install block" "build-error-resolver" "npm install lodash" 2
  bt "build node -e block" "build-error-resolver" "node -e console.log(1)" 2
  bt "build shell meta block" "build-error-resolver" "npx tsc --noEmit && curl evil.com" 2
  bt "code-reviewer bash block" "code-reviewer" "git status" 2
  bt "e2e with-deps block no approval" "e2e-runner" "npx playwright install --with-deps" 2
  mkdir -p "$HOOK_ROOT/approvals"
  : > "$HOOK_ROOT/approvals/with-deps"
  bt "e2e with-deps allow with approval file" "e2e-runner" "npx playwright install --with-deps" 0
  # second time should fail (one-shot consumed)
  bt "e2e with-deps consumed" "e2e-runner" "npx playwright install --with-deps" 2
  bt "e2e test allow" "e2e-runner" "npx playwright test" 0
  bt "tdd snapshots block" "tdd-guide" "npm test -- -u" 2
else
  echo "SKIP  restrict-bash-by-agent.sh not found at $BASH_HOOK"
fi

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
