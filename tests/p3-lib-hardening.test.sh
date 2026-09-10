#!/usr/bin/env bash
#
# p3-lib-hardening.test.sh — RED probes for the P3 hooks/lib hardening findings
# (#20, #23, #24, #25 of the 2026-09-09 audit).
#
# Each probe asserts an invariant the library does not yet hold. They are expected
# to FAIL until the corresponding fix lands.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/hooks/lib"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

TMPD="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMPD" 2>/dev/null; rm -rf "$TMPD"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

echo "==> P3 hooks/lib hardening probes (RED until fixed)"

# --- #20: consuming an approval must require the token actually be removed --------
# sec_consume_approval ends with `rm -f ... || true; return 0`, so a token that could
# not be unlinked is still reported as consumed — leaving it available for replay.
APPR="$TMPD/approvals"; mkdir -p "$APPR"
: > "$APPR/snapshots"; chmod 600 "$APPR/snapshots"

RMSTUB="$TMPD/rmstub"; mkdir -p "$RMSTUB"
for b in bash sh sed grep awk tr cat env head cut uname dirname basename date stat mv ln mktemp jq python3; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$RMSTUB/$b"
done
# `rm` that always fails, so removal cannot succeed.
printf '#!/bin/sh\nexit 1\n' > "$RMSTUB/rm"; chmod +x "$RMSTUB/rm"

rc20=0
PATH="$RMSTUB:$PATH" bash -c '
  set -uo pipefail
  source "'"$LIB"'/fs.sh"; source "'"$LIB"'/security.sh"
  sec_consume_approval "'"$APPR"'" snapshots 300
' >/dev/null 2>&1 || rc20=$?
leftover=$(ls -A "$APPR" 2>/dev/null | grep -c . || true)
if [ "$rc20" -ne 0 ]; then
  ok "#20 approval consume fails when the token cannot be removed"
else
  bad "#20 approval reported consumed while removal failed (rc=$rc20, leftover entries=$leftover)"
fi
rm -rf "$APPR"; mkdir -p "$APPR"

# --- #25: the audit log must not be written through a pre-planted symlink ---------
# HOOK_AUDIT_LOG defaults to a predictable ${TMPDIR:-/tmp} path with no symlink,
# ownership or link-count validation, so an attacker who wins the race can redirect
# every audit append into a file of their choosing.
CANARY="$TMPD/canary.txt"
printf 'ORIGINAL\n' > "$CANARY"
LOGLINK="$TMPD/audit-as-symlink.log"
ln -s "$CANARY" "$LOGLINK"

bash -c '
  set -uo pipefail
  source "'"$LIB"'/core.sh"
  hook_audit_log "'"$LOGLINK"'" "e2e-runner" "probe" "allow"
' >/dev/null 2>&1 || true

if grep -q 'rule=probe' "$CANARY" 2>/dev/null; then
  bad "#25 audit append followed a symlink and wrote into the canary"
else
  ok "#25 audit append refuses to follow a symlink"
fi

# --- #24: reading the delivered file must not block on a FIFO ---------------------
# xixi_copy_and_cleanup opens the path before checking the file type and without
# O_NONBLOCK, so a FIFO substituted after Write stalls the PostToolUse hook.
FIFO="$TMPD/xixi-prompt-a1b2c3d4"
mkfifo "$FIFO" 2>/dev/null || true
COPY_STUB="$TMPD/copy-stub.sh"
printf '#!/bin/sh\ncat > /dev/null\nexit 0\n' > "$COPY_STUB"; chmod +x "$COPY_STUB"

(
  bash -c '
    set -uo pipefail
    source "'"$LIB"'/fs.sh"; source "'"$LIB"'/xixi.sh"
    xixi_copy_and_cleanup "'"$FIFO"'" "'"$COPY_STUB"'" 100000
  ' >/dev/null 2>&1
) & probe_pid=$!
waited=0
while kill -0 "$probe_pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
  sleep 1; waited=$((waited + 1))
done
if kill -0 "$probe_pid" 2>/dev/null; then
  kill -9 "$probe_pid" 2>/dev/null
  wait "$probe_pid" 2>/dev/null
  bad "#24 copy path blocked on a FIFO for >5s (PostToolUse would hang)"
else
  wait "$probe_pid" 2>/dev/null
  ok "#24 copy path refuses a FIFO without blocking"
fi
rm -f "$FIFO"

# --- #23: no safe backend must mean refuse, not a weaker fallback -----------------
# With python3 unavailable the shell fallback reopens the path after separate
# symlink/nlink/size checks, losing the single-descriptor guarantee the Python branch
# provides. The contract says an unavailable safe backend returns the manual-copy
# fallback status instead of copying anyway.
NOPY="$TMPD/nopy"; mkdir -p "$NOPY"
for b in bash sh sed grep awk tr cat env head cut uname dirname basename date stat rm mv ln mktemp jq wc dd tail od printf test; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$NOPY/$b"
done
[ -e "$NOPY/python3" ] && { echo "FATAL: python3 leaked into the no-python stub" >&2; exit 2; }

TARGET="$TMPD/xixi-prompt-b2c3d4e5"
printf 'refined prompt\n' > "$TARGET"
MARKER="$TMPD/copied-marker"
COPY_MARK="$TMPD/copy-mark.sh"
# Shell redirection only — the probe strips PATH down to the shell fallback's own
# dependencies, so the marker must not need an external command such as touch.
printf '#!/bin/sh\ncat > "%s"\nexit 0\n' "$MARKER" > "$COPY_MARK"; chmod +x "$COPY_MARK"

rc23=0
env -i PATH="$NOPY" HOME="$TMPD" bash -c '
  set -uo pipefail
  source "'"$LIB"'/fs.sh"; source "'"$LIB"'/xixi.sh"
  xixi_copy_and_cleanup "'"$TARGET"'" "'"$COPY_MARK"'" 100000
' >/dev/null 2>&1 || rc23=$?

if [ -f "$MARKER" ]; then
  bad "#23 copied via the degraded shell fallback with no safe backend (rc=$rc23)"
else
  ok "#23 refuses to copy when the safe backend is unavailable"
fi

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
