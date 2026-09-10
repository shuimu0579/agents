#!/usr/bin/env bash
#
# p3-gate-scope.test.sh — the Bash gate governs THIS fleet, not every agent on the
# machine (ADR 0005).
#
# The hook is registered globally, so it sees Bash calls from Claude Code's built-in
# agents and from ~270 installed plugin agent definitions. It has no policy for any of
# them. Denying them was broader denial, not stronger safety: it degraded a review of
# this very repository to file-reading only, while leaving the gaps ADR 0003 already
# records untouched.
#
# The gate now ABSTAINS on an identity that is genuinely external — exit 0 without
# making an authorization decision, leaving host controls in force. It must never
# abstain because the contract is missing, malformed, or has lost a fleet row.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/hooks/restrict-bash-by-agent.sh"
LIVE_CONTRACT="$REPO_ROOT/tests/fixtures/agent-contract.tsv"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

# probe <agent> <contract> [cwd] -> exit code
probe() {
  local agent="$1" contract="$2" dir="${3:-$REPO_ROOT}" payload
  payload=$(jq -nc --arg a "$agent" \
    '{session_id:"scope-probe", agent_type:$a, tool_input:{command:"git status --porcelain"}}')
  ( cd "$dir" && printf '%s' "$payload" | env \
      AGENT_CONTRACT_FILE="$contract" HOOK_AUDIT_LOG="$TMPD/audit.log" \
      bash "$HOOK" >/dev/null 2>&1 )
  echo $?
}

echo "==> gate scope probes (ADR 0005)"

# --- fleet agents stay denied, everywhere ------------------------------------------
OUTSIDE="$TMPD/unrelated-repo"; mkdir -p "$OUTSIDE"
for a in architect code-reviewer security-reviewer _critical_thinking e2e-runner _xixi; do
  rc_in="$(probe "$a" "$LIVE_CONTRACT" "$REPO_ROOT")"
  rc_out="$(probe "$a" "$LIVE_CONTRACT" "$OUTSIDE")"
  if [ "$rc_in" -eq 2 ] && [ "$rc_out" -eq 2 ]; then
    ok "fleet: $a denied inside and outside the repo"
  else
    bad "fleet: $a not denied everywhere (inside=$rc_in outside=$rc_out)"
  fi
done

# --- genuinely external identities are abstained on --------------------------------
for a in code-review general-purpose Explore statusline-setup tdd-guardian:tdd-reviewer a-brand-new-agent; do
  rc="$(probe "$a" "$LIVE_CONTRACT")"
  [ "$rc" -eq 0 ] && ok "external: $a is out of scope (abstain)" \
                  || bad "external: $a was denied by a gate that has no policy for it (exit=$rc)"
done

# --- abstention must never be reachable through contract damage --------------------
# A fleet agent whose row was deleted still has its definition on disk. That is contract
# corruption, not an external identity, and must deny.
DAMAGED="$TMPD/row-deleted.tsv"
grep -v '^architect|' "$LIVE_CONTRACT" > "$DAMAGED"
rc="$(probe architect "$DAMAGED")"
[ "$rc" -eq 2 ] && ok "contract damage: a fleet agent with its row deleted is denied" \
                || bad "deleting a contract row turned a fleet agent into an external one (exit=$rc)"

# An empty policy field is corruption too, not absence.
EMPTYPOL="$TMPD/empty-policy.tsv"
sed 's/^architect|\(.*\)|review_only$/architect|\1|/' "$LIVE_CONTRACT" > "$EMPTYPOL"
rc="$(probe architect "$EMPTYPOL")"
[ "$rc" -eq 2 ] && ok "contract damage: an empty policy field is denied" \
                || bad "an empty policy field was treated as an unknown agent (exit=$rc)"

# An unreadable or empty contract denies everything attributed.
: > "$TMPD/empty.tsv"
rc="$(probe architect "$TMPD/empty.tsv")"
[ "$rc" -eq 2 ] && ok "contract damage: an empty contract denies fleet agents" \
                || bad "an empty contract abstained instead of denying (exit=$rc)"
rc="$(probe code-review "$TMPD/empty.tsv")"
[ "$rc" -eq 2 ] && ok "contract damage: an empty contract denies even external names" \
                || bad "an empty contract abstained (exit=$rc) — scope cannot be established"

rc="$(probe architect "$TMPD/does-not-exist.tsv")"
[ "$rc" -eq 2 ] && ok "contract damage: an unreadable contract denies" \
                || bad "an unreadable contract abstained (exit=$rc)"

# --- the main session is unaffected ------------------------------------------------
rc=$(printf '%s' '{"tool_input":{"command":"git status"}}' | \
  env AGENT_CONTRACT_FILE="$LIVE_CONTRACT" bash "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "main session (no agent_type) still passes through" \
                || bad "main session was constrained (exit=$rc)"

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
