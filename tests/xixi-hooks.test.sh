#!/usr/bin/env bash
#
# xixi-hooks.test.sh — isolated regression tests for the _xixi Write sandbox hooks.
# Uses temporary hook copies and a stub clipboard script, so it never touches the
# user's real clipboard or real hook directory.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESTRICT_HOOK_SRC="${RESTRICT_HOOK_SRC:-$HOME/.claude/agents/hooks/xixi/restrict-write.sh}"
COPY_HOOK_SRC="${COPY_HOOK_SRC:-$HOME/.claude/agents/hooks/xixi/copy-on-write.sh}"
COMMON_SRC="${COMMON_SRC:-$HOME/.claude/agents/hooks/xixi/common.sh}"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"

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
cp "$COMMON_SRC" "$HOOK_DIR/common.sh"
cp "$RESTRICT_HOOK_SRC" "$HOOK_DIR/restrict-write.sh"
cp "$COPY_HOOK_SRC" "$HOOK_DIR/copy-on-write.sh"
chmod +x "$HOOK_DIR/common.sh" "$HOOK_DIR/restrict-write.sh" "$HOOK_DIR/copy-on-write.sh"

COPY_STUB="$TMPD/copy-stub.sh"
COPIED_OUT="$TMPD/copied.txt"
cat > "$COPY_STUB" <<EOF
#!/usr/bin/env bash
cat > "$COPIED_OUT"
EOF
chmod +x "$COPY_STUB"

PASS=0
FAIL=0
RUN_RC=0
RUN_OUT=""

echo "==> _xixi hook tests (isolated HOOK_DIR=$HOOK_DIR)"

pass() {
  PASS=$((PASS + 1))
  echo "PASS  $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL  $1"
}

new_alnum_id() {
  python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(8)))
PY
}

track_path() {
  CLEANUP_PATHS+=("$1")
}

new_xixi_path() {
  local path="/tmp/xixi-prompt-$(new_alnum_id)"
  rm -f -- "$path" 2>/dev/null || true
  track_path "$path"
  printf '%s\n' "$path"
}

new_tmp_path() {
  local prefix="$1"
  local path="/tmp/${prefix}-$(new_alnum_id)"
  rm -f -- "$path" 2>/dev/null || true
  track_path "$path"
  printf '%s\n' "$path"
}

write_payload() {
  jq -nc --arg agent "$1" --arg path "$2" '{agent_type:$agent, tool_input:{file_path:$path}}'
}

run_hook() {
  local hook="$1" payload="$2"
  shift 2
  RUN_OUT="$(printf '%s' "$payload" | env COPY_SCRIPT="$COPY_STUB" "$@" bash "$hook" 2>&1)"
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

# 1. non-xixi agent Write -> pass through
path="$(new_xixi_path)"
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "code-reviewer" "/tmp/evil")"
assert_rc "non-xixi Write passes through" 0

# 2. _xixi allowed path missing -> reserve + validate inode
path="$(new_xixi_path)"
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "_xixi fresh allowed path reserves successfully" 0
assert_reserved_file "reserved file is empty regular nlink=1 owned by current uid" "$path"

# 3. _xixi bad path
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "/tmp/evil")"
assert_rc "_xixi bad path blocks" 2

# 4. _xixi pre-existing non-empty file
path="$(new_xixi_path)"
printf 'attack\n' > "$path"
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "_xixi pre-existing non-empty file blocks" 2

# 5. _xixi pre-existing empty attacker file
path="$(new_xixi_path)"
: > "$path"
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "_xixi pre-existing empty file blocks" 2

# 6. _xixi symlink target
path="$(new_xixi_path)"
target="$(new_tmp_path "xixi-symlink-target")"
printf 'target\n' > "$target"
ln -s "$target" "$path"
run_hook "$HOOK_DIR/restrict-write.sh" "$(write_payload "_xixi" "$path")"
assert_rc "_xixi symlink target blocks" 2

# 7. _xixi hard-link target
path="$(new_xixi_path)"
attacker="$(new_tmp_path "xixi-attacker")"
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
cp "$RESTRICT_HOOK_SRC" "$BROKEN_RESTRICT_DIR/restrict-write.sh"
chmod +x "$BROKEN_RESTRICT_DIR/restrict-write.sh"
path="$(new_xixi_path)"
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
path="$(new_xixi_path)"
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
path="$(new_xixi_path)"
attacker="$(new_tmp_path "xixi-copy-hardlink")"
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
cp "$COPY_HOOK_SRC" "$BROKEN_COPY_DIR/copy-on-write.sh"
chmod +x "$BROKEN_COPY_DIR/copy-on-write.sh"
run_hook "$BROKEN_COPY_DIR/copy-on-write.sh" "$(write_payload "_xixi" "/tmp/xixi-prompt-Z9y8X7w6")"
assert_rc "copy-on-write missing common.sh exits 0" 0
assert_output_contains "copy-on-write missing common.sh emits warning" "common.sh missing"

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
