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

# probe <agent> <contract> [cwd] [command] -> "<exit>\t<stderr>"
# stderr matters: an executor's allowed command and an external abstention both
# exit 0, so the gate's governance of an executor is proven by a command it
# explicitly denies (rule:allowlist), not by an exit count alone.
probe() {
  local agent="$1" contract="$2" dir="${3:-$REPO_ROOT}" cmd="${4:-git status --porcelain}"
  local payload out rc
  payload=$(jq -nc --arg a "$agent" --arg c "$cmd" \
    '{session_id:"scope-probe", agent_type:$a, tool_input:{command:$c}}')
  out="$( cd "$dir" && printf '%s' "$payload" | env \
      AGENT_CONTRACT_FILE="$contract" HOOK_AUDIT_LOG="$TMPD/audit.log" \
      bash "$HOOK" 2>&1 >/dev/null )"
  rc=$?
  printf '%s\t%s' "$rc" "$out"
}
probe_rc() { local out; out="$(probe "$@")"; printf '%s' "${out%%$'\t'*}"; }
probe_err() { local out; out="$(probe "$@")"; printf '%s' "${out#*$'\t'}"; }

echo "==> gate scope probes (ADR 0005)"

# --- review-only fleet agents stay denied, everywhere ------------------------------
OUTSIDE="$TMPD/unrelated-repo"; mkdir -p "$OUTSIDE"
for a in mark octavion atia; do
  rc_in="$(probe_rc "$a" "$LIVE_CONTRACT" "$REPO_ROOT")"
  rc_out="$(probe_rc "$a" "$LIVE_CONTRACT" "$OUTSIDE")"
  if [ "$rc_in" -eq 2 ] && [ "$rc_out" -eq 2 ] \
     && probe_err "$a" "$LIVE_CONTRACT" "$REPO_ROOT" | grep -q 'rule:review-only'; then
    ok "fleet: $a (review_only) denied inside and outside the repo"
  else
    bad "fleet: $a not denied everywhere (inside=$rc_in outside=$rc_out)"
  fi
done

# --- executor roles are governed, not merely abstained on -------------------------
# A command the allowlist explicitly refuses must deny with rule:allowlist, both
# inside and outside the fleet. Exit 0 on an allowed command would be
# indistinguishable from an external abstention.
for a in posca vorenus pullo anthory; do
  err_in="$(probe_err "$a" "$LIVE_CONTRACT" "$REPO_ROOT" "cp x hooks/y")"
  rc_in="$(probe_rc "$a" "$LIVE_CONTRACT" "$REPO_ROOT" "cp x hooks/y")"
  rc_out="$(probe_rc "$a" "$LIVE_CONTRACT" "$OUTSIDE" "cp x hooks/y")"
  if [ "$rc_in" -eq 2 ] && [ "$rc_out" -eq 2 ] \
     && printf '%s' "$err_in" | grep -q 'rule:allowlist'; then
    ok "executor: $a write command denied by rule:allowlist inside and outside"
  else
    bad "executor: $a not governed by the allowlist (inside=$rc_in outside=$rc_out)"
  fi
done
for d in "$REPO_ROOT" "$OUTSIDE"; do
  rc="$(probe_rc anthory "$LIVE_CONTRACT" "$d" "git push origin main")"
  [ "$rc" -eq 0 ] && ok "orchestrator: git push allowed in $d" \
                  || bad "orchestrator git push denied in $d (exit=$rc)"
done

# --- genuinely external identities are abstained on --------------------------------
for a in code-review general-purpose Explore statusline-setup tdd-guardian:tdd-reviewer a-brand-new-agent; do
  rc="$(probe_rc "$a" "$LIVE_CONTRACT")"
  [ "$rc" -eq 0 ] && ok "external: $a is out of scope (abstain)" \
                  || bad "external: $a was denied by a gate that has no policy for it (exit=$rc)"
done

# --- abstention must never be reachable through contract damage --------------------
# A fleet agent whose row was deleted still has its definition on disk. That is contract
# corruption, not an external identity, and must deny.
DAMAGED="$TMPD/row-deleted.tsv"
grep -v '^mark|' "$LIVE_CONTRACT" > "$DAMAGED"
rc="$(probe_rc mark "$DAMAGED")"
[ "$rc" -eq 2 ] && ok "contract damage: a fleet agent with its row deleted is denied" \
                || bad "deleting a contract row turned a fleet agent into an external one (exit=$rc)"

# An empty policy field is corruption too, not absence.
EMPTYPOL="$TMPD/empty-policy.tsv"
sed 's/^mark|\(.*\)|review_only$/mark|\1|/' "$LIVE_CONTRACT" > "$EMPTYPOL"
rc="$(probe_rc mark "$EMPTYPOL")"
[ "$rc" -eq 2 ] && ok "contract damage: an empty policy field is denied" \
                || bad "an empty policy field was treated as an unknown agent (exit=$rc)"

# An unreadable or empty contract denies everything attributed.
: > "$TMPD/empty.tsv"
rc="$(probe_rc mark "$TMPD/empty.tsv")"
[ "$rc" -eq 2 ] && ok "contract damage: an empty contract denies fleet agents" \
                || bad "an empty contract abstained instead of denying (exit=$rc)"
rc="$(probe_rc code-review "$TMPD/empty.tsv")"
[ "$rc" -eq 2 ] && ok "contract damage: an empty contract denies even external names" \
                || bad "an empty contract abstained (exit=$rc) — scope cannot be established"

rc="$(probe_rc mark "$TMPD/does-not-exist.tsv")"
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
