#!/usr/bin/env bash
#
# xixi-hooks.test.sh — isolated regression tests for the _xixi Write sandbox hooks.
# Uses temporary hook copies and a stub clipboard script, so it never touches the
# user's real clipboard or real hook directory.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESTRICT_HOOK_SRC="${RESTRICT_HOOK_SRC:-$REPO_ROOT/hooks/xixi/restrict-write.sh}"
COPY_HOOK_SRC="${COPY_HOOK_SRC:-$REPO_ROOT/hooks/xixi/copy-on-write.sh}"
COMMON_SRC="${COMMON_SRC:-$REPO_ROOT/hooks/xixi/common.sh}"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"
COPY_BACKEND_SRC="${COPY_BACKEND_SRC:-$REPO_ROOT/scripts/copy-prompt.sh}"

if [ ! -f "$RESTRICT_HOOK_SRC" ]; then
  echo "FATAL: restrict-write.sh not found at $RESTRICT_HOOK_SRC" >&2
  exit 2
fi
if [ ! -f "$COPY_HOOK_SRC" ]; then
  echo "FATAL: copy-on-write.sh not found at $COPY_HOOK_SRC" >&2
  exit 2
fi
if [ ! -f "$COMMON_SRC" ]; then
  echo "FATAL: common.sh not found at $COMMON_SRC" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq required for xixi-hooks.test.sh payloads" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 required for xixi-hooks.test.sh" >&2
  exit 2
fi

PASS=0
FAIL=0
RUN_RC=0
RUN_OUT=""

echo "==> _xixi hook tests (original executability + isolated runtime)"

pass() {
  PASS=$((PASS + 1))
  echo "PASS  $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL  $1"
}

# Check the actual installation before copying anything. Repairing modes on a
# temporary copy used to mask a non-executable original (audit #31).
for original in "$RESTRICT_HOOK_SRC" "$COPY_HOOK_SRC" "$COMMON_SRC" "$COPY_BACKEND_SRC"; do
  if [ -f "$original" ] && [ -x "$original" ]; then
    pass "original is executable: $original"
  else
    fail "original is missing or not executable: $original"
  fi
done
# Keep running the existing assertions even when a mode check fails.

TMPD="$(mktemp -d)"
CLEANUP_PATHS=()
cleanup() {
  rm -rf "$TMPD"
  local p
  if [ "${#CLEANUP_PATHS[@]}" -gt 0 ]; then
    for p in "${CLEANUP_PATHS[@]}"; do
      rm -f -- "$p" 2>/dev/null || true
    done
  fi
}
trap cleanup EXIT

HOOK_DIR="$TMPD/hooks/xixi"
mkdir -p "$HOOK_DIR"
cp -p "$COMMON_SRC" "$HOOK_DIR/common.sh"
cp -p "$RESTRICT_HOOK_SRC" "$HOOK_DIR/restrict-write.sh"
cp -p "$COPY_HOOK_SRC" "$HOOK_DIR/copy-on-write.sh"
if [[ -d "$(dirname "$COMMON_SRC")/../lib" ]]; then
  mkdir -p "$TMPD/hooks/lib"
  cp -R "$(dirname "$COMMON_SRC")/../lib/"* "$TMPD/hooks/lib/"
fi
mkdir -p "$TMPD/home/.claude" "$TMPD/approvals"

COPY_STUB="$TMPD/copy-stub.sh"
COPIED_OUT="$TMPD/copied.txt"
cat > "$COPY_STUB" <<EOF
#!/usr/bin/env bash
cat > "$COPIED_OUT"
EOF
chmod +x "$COPY_STUB"

new_alnum_id() {
  python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(8)))
PY
}

# Must not run in a command-substitution subshell — CLEANUP_PATHS lives in the parent.
alloc_tracked() {
  local _alloc_path="/tmp/${2}-$(new_alnum_id)"
  rm -f -- "$_alloc_path" 2>/dev/null || true
  CLEANUP_PATHS+=("$_alloc_path")
  eval "$1=\"\$_alloc_path\""
}

write_payload() {
  jq -nc --arg agent "$1" --arg path "$2" '{agent_type:$agent, tool_input:{file_path:$path}}'
}

run_hook() {
  local hook="$1" payload="$2"
  shift 2
  RUN_OUT="$(printf '%s' "$payload" | env -i PATH="$PATH" HOME="$TMPD/home" TMPDIR="$TMPD" \
    CLAUDE_CONFIG_DIR="$TMPD/home/.claude" APPROVAL_DIR="$TMPD/approvals" \
    HOOK_LIB_DIR="$TMPD/hooks/lib" COPY_SCRIPT="$COPY_STUB" "$@" "$hook" 2>&1)"
  RUN_RC=$?
}

assert_rc() {
  local desc="$1" expected="$2"
  if [ "$RUN_RC" -eq "$expected" ]; then
    pass "$desc"
  else
    fail "$desc (exit=$RUN_RC, want=$expected) :: $(printf '%s' "$RUN_OUT" | head -1)"
  fi
}

assert_output_contains() {
  local desc="$1" needle="$2"
  if printf '%s' "$RUN_OUT" | grep -qF "$needle"; then
    pass "$desc"
  else
    fail "$desc :: missing '$needle'"
  fi
}

assert_output_empty() {
  local desc="$1"
  if [ -z "$RUN_OUT" ]; then
    pass "$desc"
  else
    fail "$desc :: unexpected output $(printf '%s' "$RUN_OUT" | head -1)"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    pass "$desc"
  else
    fail "$desc :: path still exists ($path)"
  fi
}

assert_reserved_file() {
  local desc="$1" path="$2"
  if python3 - "$path" <<'PY'
import os, stat, sys

path = sys.argv[1]
st = os.lstat(path)
assert not stat.S_ISLNK(st.st_mode)
assert stat.S_ISREG(st.st_mode)
assert st.st_size == 0
assert st.st_nlink == 1
assert st.st_uid == os.getuid()
assert not (st.st_mode & stat.S_IWOTH)
PY
  then
    pass "$desc"
  else
    fail "$desc :: reserved file invariant failed for $path"
  fi
}

# Direct original invocation also verifies the deployed shebang/dependencies.
alloc_tracked path xixi-prompt
run_hook "$RESTRICT_HOOK_SRC" "$(write_payload "_xixi" "$path")"
assert_rc "original restrict-write executes directly and reserves a path" 0
assert_reserved_file "original direct invocation reserves a safe inode" "$path"

# 1. non-xixi agent Write -> pass through
alloc_tracked path xixi-prompt
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "code-reviewer" "/tmp/evil")"
assert_rc "non-xixi Write passes through" 0

# 1b. missing agent_type is treated as main-session pass-through (CONTRACT.md attribution prerequisite)
run_hook "$HOOK_DIR/restrict-write.sh" '{"tool_input":{"file_path":"/tmp/not-sandbox"}}'
assert_rc "missing agent_type Write passes through" 0

# 2. _xixi allowed path missing -> reserve + validate inode
alloc_tracked path xixi-prompt
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "_xixi fresh allowed path reserves successfully" 0
assert_reserved_file "reserved file is empty regular nlink=1 owned by current uid" "$path"

# 3. _xixi bad path
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "/tmp/evil")"
assert_rc "_xixi bad path blocks" 2

# 4. _xixi pre-existing non-empty file
alloc_tracked path xixi-prompt
printf 'attack\n' > "$path"
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "_xixi pre-existing non-empty file blocks" 2

# 5. _xixi pre-existing empty attacker file
alloc_tracked path xixi-prompt
: > "$path"
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "_xixi pre-existing empty file blocks" 2

# 6. _xixi symlink target
alloc_tracked path xixi-prompt
alloc_tracked target xixi-symlink-target
printf 'target\n' > "$target"
ln -s "$target" "$path"
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "_xixi symlink target blocks" 2

# 7. _xixi hard-link target
alloc_tracked path xixi-prompt
alloc_tracked attacker xixi-attacker
: > "$attacker"
ln "$attacker" "$path"
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "_xixi hard-link target blocks" 2

# 8. malformed JSON naming _xixi -> fail closed
run_hook "$HOOK_DIR/restrict-write.sh" '{"agent_type":"_xixi","tool_input":{"file_path":"/tmp/xixi-prompt-ABC123xy"'
assert_rc "_xixi malformed JSON blocks" 2

# 9. missing common.sh -> fail closed
BROKEN_RESTRICT_DIR="$TMPD/broken-restrict"
mkdir -p "$BROKEN_RESTRICT_DIR"
cp -p "$RESTRICT_HOOK_SRC" "$BROKEN_RESTRICT_DIR/restrict-write.sh"
alloc_tracked path xixi-prompt
run_hook "$BROKEN_RESTRICT_DIR/restrict-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "restrict-write missing common.sh blocks" 2

# 10. settings.json registers both xixi Write hooks
if [ -f "$SETTINGS" ] && python3 - "$SETTINGS" <<'PY'
import json, sys

settings = json.load(open(sys.argv[1]))
pre = [
    hook.get("command", "")
    for rule in settings.get("hooks", {}).get("PreToolUse", [])
    if rule.get("matcher") == "Write"
    for hook in rule.get("hooks", [])
]
post = [
    hook.get("command", "")
    for rule in settings.get("hooks", {}).get("PostToolUse", [])
    if rule.get("matcher") == "Write"
    for hook in rule.get("hooks", [])
]
sys.exit(0 if any("restrict-write.sh" in c for c in pre) and any("copy-on-write.sh" in c for c in post) else 1)
PY
then
  pass "settings.json registers both _xixi Write hooks"
else
  fail "settings.json missing _xixi Write hook registration (SETTINGS=$SETTINGS)"
fi

# 11. copy-on-write non-xixi path shape -> no status
run_hook "$HOOK_DIR/copy-on-write.sh" "$(write_payload "_xixi" "/tmp/not-xixi")"
assert_rc "copy-on-write non-xixi path shape exits 0" 0
assert_output_empty "copy-on-write non-xixi path shape emits no status"

# 12. copy-on-write success path -> ✅ + unlink + stub capture
alloc_tracked path xixi-prompt
printf 'refined prompt body\n' > "$path"
run_hook "$HOOK_DIR/copy-on-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "copy-on-write success exits 0" 0
assert_output_contains "copy-on-write success emits ✅" "✅ refined prompt copied to clipboard"
if [ -f "$COPIED_OUT" ] && [ "$(cat "$COPIED_OUT")" = "refined prompt body" ]; then
  pass "copy-on-write success uses stub clipboard script"
else
  fail "copy-on-write success did not copy expected bytes"
fi
assert_file_missing "copy-on-write success unlinks temp file" "$path"

# 13. copy-on-write hard-link defense -> warn + unlink xixi path
alloc_tracked path xixi-prompt
alloc_tracked attacker xixi-copy-hardlink
printf 'linked prompt\n' > "$attacker"
ln "$attacker" "$path"
run_hook "$HOOK_DIR/copy-on-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "copy-on-write hard-link exits 0" 0
assert_output_contains "copy-on-write hard-link emits warning" "multi-link file"
assert_file_missing "copy-on-write hard-link unlinks xixi temp path" "$path"

# 14. copy-on-write malformed JSON with xixi attribution -> warn, do not copy
rm -f -- "$COPIED_OUT" 2>/dev/null || true
run_hook "$HOOK_DIR/copy-on-write.sh" '{"agent_type":"_xixi","tool_input":{"file_path":"/tmp/xixi-prompt-AbC123xy"'
assert_rc "copy-on-write malformed JSON exits 0" 0
assert_output_contains "copy-on-write malformed JSON emits warning" "malformed JSON prevented _xixi hook attribution"
assert_file_missing "copy-on-write malformed JSON does not create clipboard output" "$COPIED_OUT"

# 15. copy-on-write missing common.sh -> warn, not silent success
BROKEN_COPY_DIR="$TMPD/broken-copy"
mkdir -p "$BROKEN_COPY_DIR"
cp -p "$COPY_HOOK_SRC" "$BROKEN_COPY_DIR/copy-on-write.sh"
run_hook "$BROKEN_COPY_DIR/copy-on-write.sh" "$(write_payload "_xixi" "/tmp/xixi-prompt-Z9y8X7w6")"
assert_rc "copy-on-write missing common.sh exits 0" 0
assert_output_contains "copy-on-write missing common.sh emits warning" "common.sh missing"

# --- Dependency/failure matrix (audit #32) ------------------------------------
# A restricted PATH is the ENTIRE child PATH, never prepended to the real one.
# The complete control proves that a probe cannot pass because another dependency
# accidentally vanished. Payload creation/assertions run on the parent's PATH.
STUB_PATH="$TMPD/path-control"
mkdir -p "$STUB_PATH" "$TMPD/no-jq" "$TMPD/no-python"
for binary in bash sh cat dirname basename grep jq python3 stat wc tr rm date \
              sed awk head cut uname env mktemp readlink id; do
  binary_src="$(type -P "$binary")" || { echo "FATAL: missing probe dependency $binary" >&2; exit 2; }
  ln -s "$binary_src" "$STUB_PATH/$binary"
  [ "$binary" = jq ] || ln -s "$binary_src" "$TMPD/no-jq/$binary"
  [ "$binary" = python3 ] || ln -s "$binary_src" "$TMPD/no-python/$binary"
done
if [ -e "$TMPD/no-jq/jq" ] || [ -e "$TMPD/no-python/python3" ]; then
  echo "FATAL: dependency leaked into restricted PATH" >&2
  exit 2
fi

# PreToolUse failures must be explicit denials, leave no reservation, and never
# invoke the clipboard backend. File absence is checked BEFORE the suite's trap.
pre_failure() {
  local desc="$1" hook="$2" payload="$3" reason="$4"
  shift 4
  rm -f -- "$COPIED_OUT"
  run_hook "$hook" "$payload" "$@"
  assert_rc "$desc exits 2" 2
  assert_output_contains "$desc emits the specific denial" "$reason"
  assert_file_missing "$desc leaves no reserved temp file" "$path"
  assert_file_missing "$desc writes nothing to clipboard" "$COPIED_OUT"
}

alloc_tracked path xixi-prompt
pre_failure "restrict missing jq" "$HOOK_DIR/restrict-write.sh" \
  "$(write_payload _xixi "$path")" "jq unavailable" "PATH=$TMPD/no-jq"
alloc_tracked path xixi-prompt
pre_failure "restrict missing python3" "$HOOK_DIR/restrict-write.sh" \
  "$(write_payload _xixi "$path")" "could not exclusively create target" "PATH=$TMPD/no-python"
for wrong_type in array string; do
  alloc_tracked path xixi-prompt
  payload="$(write_payload _xixi "$path")"
  if [ "$wrong_type" = array ]; then payload="[$payload]"
  else payload="$(printf '%s' "$payload" | jq -Rs .)"; fi
  pre_failure "restrict wrong JSON type ($wrong_type)" "$HOOK_DIR/restrict-write.sh" \
    "$payload" "rule:schema"
done

# Source the real facade, then remove ONE required helper to isolate that failure.
MISSING_HELPER_DIR="$TMPD/missing-helper"
mkdir -p "$MISSING_HELPER_DIR"
cp -p "$RESTRICT_HOOK_SRC" "$COPY_HOOK_SRC" "$COMMON_SRC" "$MISSING_HELPER_DIR/"
printf '\nunset -f is_allowed_xixi_path\n' >> "$MISSING_HELPER_DIR/common.sh"
alloc_tracked path xixi-prompt
pre_failure "restrict missing required helper" "$MISSING_HELPER_DIR/restrict-write.sh" \
  "$(write_payload _xixi "$path")" "missing required helper is_allowed_xixi_path"

# Every PostToolUse failure must remain exit 0, deliver a cause-specific manual-copy
# fallback, remove its temporary output, and leave the fake clipboard untouched.
# These are desired invariants, not snapshots of currently buggy early returns.
post_failure() {
  local desc="$1" hook="$2" payload="$3" reason="$4" status
  shift 4
  rm -f -- "$COPIED_OUT"
  run_hook "$hook" "$payload" "$@"
  assert_rc "$desc exits 0" 0
  if [ "$reason" = "jq missing" ]; then
    status="$RUN_OUT"  # This dependency failure must support plain text.
  else
    # With jq available, a stderr warning alone is not a host-visible status.
    status="$(printf '%s' "$RUN_OUT" | jq -r '
      select(.hookSpecificOutput.hookEventName == "PostToolUse") |
      .hookSpecificOutput.additionalContext | strings' 2>/dev/null)"
  fi
  if [[ "$status" == *"⚠️"* && "$status" == *"$reason"* &&
        "$status" == *"Paste the full refined prompt into chat as fallback"* &&
        "$status" != *"✅"* ]]; then
    pass "$desc emits cause-specific manual-copy fallback"
  else
    fail "$desc missing fallback for '$reason' :: $RUN_OUT"
  fi
  assert_file_missing "$desc cleans temp file" "$path"
  assert_file_missing "$desc writes nothing to clipboard" "$COPIED_OUT"
}

# Positive control uses an ORIGINAL hook directly under the complete stub PATH.
alloc_tracked path xixi-prompt
printf 'PATH control prompt\n' > "$path"
rm -f -- "$COPIED_OUT"
run_hook "$COPY_HOOK_SRC" "$(write_payload _xixi "$path")" "PATH=$STUB_PATH"
assert_rc "complete PATH control: original copy hook exits 0" 0
assert_output_contains "complete PATH control emits success" "✅ refined prompt copied to clipboard"
assert_file_missing "complete PATH control cleans temp file" "$path"
if [ -f "$COPIED_OUT" ] && [ "$(cat "$COPIED_OUT")" = "PATH control prompt" ]; then
  pass "complete PATH control copies the exact bytes to the stub"
else
  fail "complete PATH control did not exercise the clipboard backend"
fi

alloc_tracked path xixi-prompt
printf 'prompt\n' > "$path"
post_failure "copy missing jq" "$HOOK_DIR/copy-on-write.sh" \
  "$(write_payload _xixi "$path")" "jq missing" "PATH=$TMPD/no-jq"
alloc_tracked path xixi-prompt
printf 'prompt\n' > "$path"
post_failure "copy missing python3" "$HOOK_DIR/copy-on-write.sh" \
  "$(write_payload _xixi "$path")" "python3 unavailable" "PATH=$TMPD/no-python"
alloc_tracked path xixi-prompt
printf 'prompt\n' > "$path"
post_failure "copy wrong JSON type (array)" "$HOOK_DIR/copy-on-write.sh" \
  "[$(write_payload _xixi "$path")]" "JSON object"
alloc_tracked path xixi-prompt
printf 'prompt\n' > "$path"
post_failure "copy missing required helper" "$MISSING_HELPER_DIR/copy-on-write.sh" \
  "$(write_payload _xixi "$path")" "helper is_allowed_xixi_path missing"
alloc_tracked path xixi-prompt
: > "$path"
post_failure "copy empty output" "$HOOK_DIR/copy-on-write.sh" \
  "$(write_payload _xixi "$path")" "empty file"
alloc_tracked path xixi-prompt
python3 - "$path" <<'OVERSIZE'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_bytes(b"x" * (524288 + 1))
OVERSIZE
post_failure "copy output over 512 KiB cap" "$HOOK_DIR/copy-on-write.sh" \
  "$(write_payload _xixi "$path")" "too large (> 524288 bytes)"

FAIL_BACKEND="$TMPD/failing-clipboard.sh"
BACKEND_CALLED="$TMPD/backend-called"
cat > "$FAIL_BACKEND" <<EOF
#!/bin/sh
printf 'called\\n' > "$BACKEND_CALLED"
cat > /dev/null
exit 1
EOF
chmod +x "$FAIL_BACKEND"
alloc_tracked path xixi-prompt
printf 'prompt\n' > "$path"
post_failure "copy failing clipboard backend" "$HOOK_DIR/copy-on-write.sh" \
  "$(write_payload _xixi "$path")" "clipboard copy failed" "COPY_SCRIPT=$FAIL_BACKEND"
if [ -f "$BACKEND_CALLED" ] && [ "$(cat "$BACKEND_CALLED")" = called ]; then
  pass "failing clipboard backend was actually invoked"
else
  fail "clipboard failure probe did not reach the backend"
fi

# --- Attribution matrix (audit #43) -------------------------------------------
# The sandbox applies ONLY when the host stamps agent_type on the Write event.
# CONTRACT.md records that this prerequisite has never been re-verified against a
# live harness, and nothing here can verify it — these assertions pin the HOOK
# side of the contract so a regression in the hook cannot be mistaken for the
# host-side gap. See CONTRACT.md "Attribution prerequisite" for the manual check.

run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "/tmp/outside-the-sandbox.txt")"
assert_rc "attribution: _xixi outside the sandbox is denied" 2

run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "xixi" "/tmp/outside-the-sandbox.txt")"
assert_rc "attribution: bare 'xixi' spelling is denied the same way" 2

run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "e2e-runner" "/tmp/outside-the-sandbox.txt")"
assert_rc "attribution: a different agent is not this hook's business" 0

run_hook "$HOOK_DIR/restrict-write.sh" "$(jq -nc '{tool_input:{file_path:"/tmp/outside-the-sandbox.txt"}}')"
assert_rc "attribution: absent agent_type passes through as main session" 0

# The pass-through above is exactly the failure mode CONTRACT.md warns about: if a
# future harness omits agent_type on subagent Write, _xixi is unconstrained and this
# suite still goes green. That is a host contract, not a hook bug — assert the shape
# so the distinction stays visible.
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "/etc/passwd")"
assert_rc "attribution: sandbox denial is path-based, not extension-based" 2

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
