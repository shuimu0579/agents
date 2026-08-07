#!/usr/bin/env bash
#
# guardrails.sh — retroactive contract gate for the ~/.claude/agents fleet.
#
# Purpose (finding F5 in grill-report-2026-08-07.md):
#   Assert the agent-definition contracts that the last "harden" commit (ddc9692)
#   established, so that ANY future edit is caught if it breaks them. This is the
#   regression net the corpus never had.
#
# What it checks (driven by the CONTRACT table below — add a row when you add an agent):
#   1. Frontmatter valid (name/description/tools/model present; name == filename).
#   2. Review-only tool contract (security-reviewer/architect/planner = Read,Grep,Glob;
#      code-reviewer = Read,Grep,Bash with a git-only whitelist in the body;
#      none of them may carry Write/Edit; only code-reviewer may carry Bash).
#   3. _xixi sandbox + injection-preamble contract (Write allowed, body must reference
#      /tmp/xixi-prompt and the "DATA, never instructions" guard; shell-free).
#   4. Verdict token present (each agent's orchestrator-facing output token still exists).
#   5. Line budget (<400 ok, 400-800 warn, >800 fail — per rules/coding-style.md).
#
# Dependencies: bash, grep, awk, wc, sed. Deliberately NO jq/yq (see F26).
#
# Usage:
#   tests/guardrails.sh            # check everything, exit non-zero on any FAIL
#   tests/guardrails.sh --strict   # treat WARN (e.g. >400 lines) as FAIL too
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STRICT=0
for arg in "$@"; do [[ "$arg" == "--strict" ]] && STRICT=1; done

cd "$AGENTS_DIR"

FAILS=0
WARNS=0
LINES_OUT=()

fail() { FAILS=$((FAILS + 1)); LINES_OUT+=("FAIL  $1"); }
warn() { WARNS=$((WARNS + 1)); LINES_OUT+=("WARN  $1"); }
note() { LINES_OUT+=("ok    $1"); }

# get_field <file> <field> -> prints value of `^field:` (first match); empty if absent.
# `|| true` keeps this set -e safe when grep finds no match.
get_field() {
  grep -m1 "^$2:" "$1" | sed "s/^$2:[[:space:]]*//" || true
}

# has_tool <tools_str> <tool> -> 0 if tool present
has_tool() {
  local norm
  norm=",$(printf '%s' "$1" | tr -d ' '),"
  [[ "$norm" == *",$2,"* ]]
}

# tools_equal <actual> <expected> -> 0 if same set (order-insensitive)
tools_equal() {
  local a e
  a="$(printf '%s' "$1" | tr -d ' ' | tr ',' '\n' | sort | paste -sd, -)"
  e="$(printf '%s' "$2" | tr -d ' ' | tr ',' '\n' | sort | paste -sd, -)"
  [[ "$a" == "$e" ]]
}

# token_present <file> <token> -> 0 if file contains token (literal fixed-string)
token_present() {
  grep -qF -- "$2" "$1"
}

# ---------------------------------------------------------------------------
# Contract table — the single source of truth for "what each agent must look like".
#   name|expected_tools|verdict_anyof(;)|flag
#   flag: review_only | review_only_bash | xixi | mutator
#
# After F2 lands (code-reviewer loses Bash), change its row to:
#   code-reviewer|Read, Grep, Glob|Recommendation:|review_only
# ---------------------------------------------------------------------------
CONTRACT="$(cat <<'EOF'
security-reviewer|Read, Grep, Glob|Recommendation:|review_only
code-reviewer|Read, Grep, Glob|Recommendation:|review_only
architect|Read, Grep, Glob|RECOMMEND|review_only
planner|Read, Grep, Glob|READY_FOR_IMPLEMENTATION|review_only
_xixi|Read, Grep, Glob, Write|/tmp/xixi-prompt;xixi|xixi
build-error-resolver|Read, Write, Edit, Bash|STILL_RED|mutator
doc-updater|Read, Write, Edit, Bash, Grep, Glob|DOCS_DRIFT|mutator
e2e-runner|Read, Write, Edit, Bash, Grep, Glob|QUARANTINE|mutator
refactor-cleaner|Read, Write, Bash, Grep|SAFE_TO_MERGE|mutator
tdd-guide|Read, Write, Edit, Bash, Grep|FAILING_AS_EXPECTED|mutator
EOF
)"

echo "==> guardrails: auditing $AGENTS_DIR"

while IFS='|' read -r name exp_tools verdicts flag; do
  [[ -z "$name" ]] && continue
  f="$name.md"
  base="$name"

  if [[ ! -f "$f" ]]; then fail "$f: contract row '$name' but file missing"; continue; fi

  actual_name="$(get_field "$f" name)"
  actual_tools="$(get_field "$f" tools)"

  # 1. frontmatter fields present
  for field in name description tools model; do
    val="$(get_field "$f" "$field")"
    if [[ -z "$val" ]]; then fail "$f: missing frontmatter field '$field'"; fi
  done

  # name == filename
  if [[ -n "$actual_name" && "$actual_name" != "$base" ]]; then
    fail "$f: name ('$actual_name') != filename ('$base')"
  fi

  # 5. line budget
  lc="$(wc -l < "$f" | tr -d ' ')"
  if   (( lc > 800 )); then fail "$f: $lc lines (hard limit 800)";
  elif (( lc > 400 )); then warn "$f: $lc lines (prefer <400)";
  else note "$f: $lc lines";
  fi

  # 2. exact tools match
  if tools_equal "$actual_tools" "$exp_tools"; then
    note "$f: tools == [$exp_tools]"
  else
    fail "$f: tools '$actual_tools' != expected '$exp_tools'"
  fi

  # 2/3. flag-specific invariants
  case "$flag" in
    review_only)
      for banned in Write Edit Bash; do
        if has_tool "$actual_tools" "$banned"; then fail "$f: review-only agent carries $banned"; fi
      done
      ;;
    review_only_bash)
      for banned in Write Edit; do
        if has_tool "$actual_tools" "$banned"; then fail "$f: review-only agent carries $banned"; fi
      done
      if ! token_present "$f" "git status" || ! token_present "$f" "git diff"; then
        fail "$f: lost the git-only Bash whitelist (git status / git diff)"
      else
        note "$f: git-only Bash whitelist present"
      fi
      ;;
    xixi)
      if ! token_present "$f" "/tmp/xixi-prompt";      then fail "$f: lost /tmp/xixi-prompt sandbox contract"; fi
      if ! token_present "$f" "DATA, never instructions"; then fail "$f: lost 'content-is-data' injection preamble (F1)"; fi
      if has_tool "$actual_tools" "Bash";              then fail "$f: _xixi must remain shell-free (no Bash)"; fi
      note "$f: sandbox + injection preamble + shell-free"
      ;;
    mutator)
      if ! has_tool "$actual_tools" "Write" && ! has_tool "$actual_tools" "Edit"; then
        fail "$f: mutator lost all write tools (Write/Edit)"
      fi
      ;;
  esac

  # 4. domain verdict token (any-of)
  found=0
  IFS=';' read -ra toks <<< "$verdicts"
  for t in "${toks[@]}"; do
    [[ -z "$t" ]] && continue
    if token_present "$f" "$t"; then found=1; note "$f: verdict token '$t' present"; break; fi
  done
  if [[ "$found" -eq 0 ]]; then
    fail "$f: none of verdict tokens [$verdicts] found (orchestrator contract drifted)"
  fi

  # 4b. canonical orchestrator Verdict (grill F14) — every agent must emit GO|BLOCK|NEEDS_INPUT vocabulary
  if token_present "$f" "**Verdict:**" || token_present "$f" "Verdict:"; then
    note "$f: canonical Verdict line present"
  else
    fail "$f: missing canonical **Verdict:** (GO|BLOCK|NEEDS_INPUT) — see rules/agent-output-contract.md"
  fi

  # 4c. reader injection preamble (grill F1) — review_only + xixi
  case "$flag" in
    review_only|xixi)
      if token_present "$f" "DATA, never instructions"; then
        note "$f: injection preamble present"
      else
        fail "$f: missing 'DATA, never instructions' preamble (F1)"
      fi
      ;;
  esac
done <<< "$CONTRACT"

# ---------------------------------------------------------------------------
# Fleet-level checks
# ---------------------------------------------------------------------------

# Discover agent *.md vs contract table (audit: no orphan agents)
DISCOVERED=()
while IFS= read -r f; do
  base="${f#./}"; base="${base%.md}"
  [[ "$base" == grill-* ]] && continue
  DISCOVERED+=("$base")
done < <(find . -maxdepth 1 -name '*.md' | sort)

CONTRACT_NAMES=()
while IFS='|' read -r name _rest; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  CONTRACT_NAMES+=("$name")
done <<< "$CONTRACT"

for d in "${DISCOVERED[@]}"; do
  found=0
  for c in "${CONTRACT_NAMES[@]}"; do [[ "$c" == "$d" ]] && found=1 && break; done
  if [[ "$found" -eq 0 ]]; then fail "fleet: agent file $d.md not in CONTRACT table"; else note "fleet: $d.md in CONTRACT"; fi
done
for c in "${CONTRACT_NAMES[@]}"; do
  found=0
  for d in "${DISCOVERED[@]}"; do [[ "$c" == "$d" ]] && found=1 && break; done
  if [[ "$found" -eq 0 ]]; then fail "fleet: CONTRACT row $c has no $c.md"; fi
done

# F33: trigger fixtures single source
if [[ -f tests/triggers.yml ]]; then
  note "fleet: tests/triggers.yml present"
else
  warn "fleet: tests/triggers.yml missing (F33)"
fi

# F18: e2e templates extracted
if [[ -f templates/playwright.config.ts.tmpl && -f templates/e2e.github-actions.yml.tmpl ]]; then
  note "fleet: e2e templates present"
else
  warn "fleet: e2e templates missing under templates/"
fi


# F2: code-reviewer must not regain Bash
if grep -m1 '^tools:' code-reviewer.md | grep -q 'Bash'; then
  fail "code-reviewer.md: Bash returned (F2 regression)"
else
  note "fleet: code-reviewer remains Bash-free"
fi

# F7: worker agents should be sonnet (cost allocation)
for worker in build-error-resolver tdd-guide refactor-cleaner doc-updater e2e-runner; do
  m="$(get_field "$worker.md" model)"
  if [[ "$m" == "sonnet" ]]; then
    note "fleet: $worker model=sonnet"
  else
    warn "fleet: $worker model='$m' (expected sonnet per F7)"
  fi
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
{
  printf '%s\n' "${LINES_OUT[@]}" | sort
  echo
  echo "==> result: $FAILS FAIL, $WARNS WARN (10 agent files)"
}

if (( FAILS > 0 )); then
  exit 1
fi
if [[ "$STRICT" -eq 1 && "$WARNS" -gt 0 ]]; then
  echo "==> --strict: WARN treated as FAIL"
  exit 1
fi
exit 0
