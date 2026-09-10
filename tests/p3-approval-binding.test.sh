#!/usr/bin/env bash
#
# p3-approval-binding.test.sh — probes for audit #21: one-shot approval tokens carry
# no binding, so a token minted for one session or one repository can be consumed by
# another.
#
# Scope note: cross-COMMAND borrow is already prevented — the gate branches on the
# command family and consumes the token only after launcher, option and config
# validation (P1, commit 3f66bdc). What is unbound is session and repository.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/hooks/restrict-bash-by-agent.sh"
MINT="$REPO_ROOT/scripts/create-approval.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
CONTRACT="$TMPD/contract.tsv"
awk -F'|' -v OFS='|' '$1=="e2e-runner"{$2="Read, Write, Edit, Bash, Grep, Glob"}1' \
  "$REPO_ROOT/tests/fixtures/agent-contract.tsv" > "$CONTRACT"
APPR="$TMPD/approvals"; mkdir -p "$APPR"
CWD="$TMPD/cwd"; mkdir -p "$CWD"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

SNAP_CMD='playwright test --update-snapshots'
SESSION_A="session-aaaa-1111"
SESSION_B="session-bbbb-2222"

# run <session_id> <cwd> -> exit code
run() {
  local sid="$1" dir="$2" payload
  payload=$(jq -nc --arg s "$sid" --arg c "$SNAP_CMD" \
    '{session_id:$s, agent_type:"e2e-runner", tool_input:{command:$c}}')
  ( cd "$dir" && printf '%s' "$payload" | env \
      AGENT_CONTRACT_FILE="$CONTRACT" APPROVAL_DIR="$APPR" \
      BASE_URL=http://localhost:3000 bash "$HOOK" >/dev/null 2>&1 )
  echo $?
}

mint() {  # mint <session_id>
  rm -f "$APPR"/snapshots*
  if [ -x "$MINT" ]; then
    APPROVAL_DIR="$APPR" bash "$MINT" snapshots "$1" >/dev/null 2>&1
  else
    : > "$APPR/snapshots"; chmod 600 "$APPR/snapshots"   # legacy unbound token
  fi
}

echo "==> approval binding probes (audit #21)"

# --- a correctly bound token still works, exactly once -------------------------
mint "$SESSION_A"
rc="$(run "$SESSION_A" "$REPO_ROOT")"
[ "$rc" -eq 0 ] && ok "bound token authorizes its own session" \
                || bad "bound token was rejected for its own session (exit=$rc)"
rc="$(run "$SESSION_A" "$REPO_ROOT")"
[ "$rc" -eq 2 ] && ok "bound token is still one-shot" \
                || bad "bound token was reusable (exit=$rc)"

# --- a token minted for session A must not authorize session B -----------------
mint "$SESSION_A"
rc="$(run "$SESSION_B" "$REPO_ROOT")"
if [ "$rc" -eq 2 ]; then ok "token minted for session A is refused for session B"
else bad "session B consumed session A's approval (exit=$rc)"; fi
if [ -f "$APPR/snapshots" ]; then ok "refused attempt leaves the token for its owner"
else bad "refused attempt destroyed a token belonging to another session"; fi

# --- a token minted for a DIFFERENT fleet must not be honoured here ------------
# The repo binding is derived from the hook's own location, so it does not vary with
# the caller's cwd — a run from another directory is still this fleet's gate, and
# refusing it would be wrong. What the binding guards is a token file that was minted
# elsewhere and then placed in this approval directory.
rm -f "$APPR"/snapshots*
{ printf 'session=%s\n' "$SESSION_A"; printf 'repo=%s\n' "/some/other/fleet"; } > "$APPR/snapshots"
chmod 600 "$APPR/snapshots"
rc="$(run "$SESSION_A" "$REPO_ROOT")"
if [ "$rc" -eq 2 ]; then ok "token minted for a different fleet is refused"
else bad "a token naming another repository was accepted here (exit=$rc)"; fi

# A run from a different working directory is still this fleet's gate and must work.
OTHER="$TMPD/other-cwd"; mkdir -p "$OTHER"
mint "$SESSION_A"
rc="$(run "$SESSION_A" "$OTHER")"
if [ "$rc" -eq 0 ]; then ok "same session from another cwd is still authorized"
else bad "binding wrongly rejected the owning session because of its cwd (exit=$rc)"; fi

# --- a legacy unbound token must not be honoured ------------------------------
rm -f "$APPR"/snapshots*
: > "$APPR/snapshots"; chmod 600 "$APPR/snapshots"
rc="$(run "$SESSION_A" "$REPO_ROOT")"
if [ "$rc" -eq 2 ]; then ok "an unbound legacy token is refused"
else bad "an empty token with no binding fields still authorized the command (exit=$rc)"; fi

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
