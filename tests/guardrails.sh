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
#   1. Frontmatter valid (name/description required; optional tools/model valid when present; name == filename).
#   2. Review-only tool contract (architect/code-reviewer/security-reviewer = Read,Grep,Glob;
#      none may carry Write/Edit/Bash).
#   3. Mutator contract (e2e-runner carries Write/Edit; verdict token QUARANTINE).
#   4. Verdict token present (each agent's orchestrator-facing output token still exists).
#   5. Line budget (<400 ok, 400-800 warn, >800 fail — per rules/coding-style.md).
#   6. NF1: archive/ must contain no *.md (Claude Code scans recursively — a .md there is a live agent).
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
  a="$(printf '%s' "$1" | tr -d '[]"' | tr -d "' " | tr ',' '\n' | sort | paste -sd, -)"
  e="$(printf '%s' "$2" | tr -d '[]"' | tr -d "' " | tr ',' '\n' | sort | paste -sd, -)"
  [[ "$a" == "$e" ]]
}

# tools_field_valid <tools_str> -> 0 for documented comma strings or JSON arrays of tool names
tools_field_valid() {
  local value token
  value="$(printf '%s' "$1" | tr -d '[]"' | tr -d "' ")"
  [[ -n "$value" ]] || return 1
  IFS=',' read -ra tool_tokens <<< "$value"
  for token in "${tool_tokens[@]}"; do
    [[ "$token" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || return 1
  done
}

# model_field_valid <model> -> 0 for documented aliases or a single full model ID
model_field_valid() {
  [[ "$1" =~ ^(haiku|sonnet|opus|fable|inherit|[A-Za-z0-9][A-Za-z0-9._:-]*)$ ]]
}

# token_present <file> <token> -> 0 if file contains token (literal fixed-string)
token_present() {
  grep -qF -- "$2" "$1"
}

# ---------------------------------------------------------------------------
# Contract table — the single source of truth for "what each agent must look like".
#   name|expected_tools|verdict_anyof(;)|flag
#   flag: review_only | mutator
# ---------------------------------------------------------------------------
CONTRACT="$(cat <<'EOF'
security-reviewer|Read, Grep, Glob|APPROVE WITH CHANGES|review_only
code-reviewer|Read, Grep, Glob|APPROVE WITH CHANGES|review_only
architect|Read, Grep, Glob|RECOMMEND|review_only
e2e-runner|Read, Write, Edit, Bash, Grep, Glob|QUARANTINE|mutator
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
  actual_model="$(get_field "$f" model)"

  # 1. frontmatter fields present
  # name + description: required; tools + model: optional per official schema (N7)
  for field in name description; do
    val="$(get_field "$f" "$field")"
    if [[ -z "$val" ]]; then fail "$f: missing required frontmatter field '$field'"; fi
  done
  if [[ -z "$actual_tools" ]]; then
    fail "$f: missing frontmatter field 'tools' (fleet invariant — omission inherits the parent tool pool)"
  elif tools_field_valid "$actual_tools"; then
    note "$f: tools present and valid"
  else
    fail "$f: invalid frontmatter field 'tools': '$actual_tools'"
  fi
  if [[ -z "$actual_model" ]]; then
    fail "$f: missing frontmatter field 'model' (fleet invariant — model pins per D2)"
  elif model_field_valid "$actual_model"; then
    note "$f: model present and valid"
  else
    fail "$f: invalid frontmatter field 'model': '$actual_model'"
  fi

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
  if [[ -z "$actual_tools" ]]; then
    note "$f: exact tools contract skipped because optional field is omitted"
  elif tools_equal "$actual_tools" "$exp_tools"; then
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
    mutator)
      if [[ -n "$actual_tools" ]] && ! has_tool "$actual_tools" "Write" && ! has_tool "$actual_tools" "Edit"; then
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
  if token_present "$f" "**Verdict:**"; then
    note "$f: canonical Verdict line present"
  else
    fail "$f: missing canonical **Verdict:** (bold, GO|BLOCK|NEEDS_INPUT) — see rules/agent-output-contract.md"
  fi

  # 4b2. Verdict must be the final template line, after ## Handoff (contract: final line) — D-TOKEN freeze
  _hln="$(grep -n '^## Handoff' "$f" | head -1 | cut -d: -f1)"
  _vln="$(grep -n '^\*\*Verdict:\*\*' "$f" | head -1 | cut -d: -f1)"
  if [[ -n "$_hln" && -n "$_vln" && "$_vln" -gt "$_hln" ]]; then
    note "$f: Verdict after Handoff (final-line contract)"
  else
    fail "$f: **Verdict:** must come after ## Handoff as the final template line (contract)"
  fi

  # 4c. reader injection preamble (grill F1) — review_only + mutator
  case "$flag" in
    review_only|mutator)
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

# Discover agent *.md vs contract table (audit: no orphan agents).
# Mirrors Claude Code's recursive scan: any *.md with agent frontmatter (name+description)
# outside the excluded dirs is a candidate. Reports/docs/tests/templates/hooks/archive excluded.
DISCOVERED=()
while IFS= read -r f; do
  base="${f#./}"; base="${base%.md}"
  # Skip non-agent paths
  case "$f" in
    ./CLAUDE.md|./archive/*|./docs/*|./tests/*|./templates/*|./scripts/*|./hooks/*|./.github/*|./.git/*|./.claude/*|./grill-report-*|./codex-*) continue ;;
  esac
  [[ "$base" == .* ]] && continue
  # Only agent-like files (agent frontmatter present) count — reports/docs are not agents
  if grep -qE '^name:' "$f" && grep -qE '^description:' "$f"; then
    DISCOVERED+=("$base")
  fi
done < <(find . -name '*.md' -not -path './.git/*' | sort)

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

# NF1: archive/ is not a runtime boundary — Claude Code scans recursively.
# Tolerant when archive/ is absent (fresh checkout before the consolidation commit lands).
ARCHIVE_MDS=0
if [[ -d archive ]]; then
  ARCHIVE_MDS="$(find archive -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
fi
if [[ "${ARCHIVE_MDS:-0}" -gt 0 ]]; then
  fail "archive/: $ARCHIVE_MDS retired agent(s) still end in .md and are runtime-loadable (NF1) — rename to .md.disabled"
else
  note "fleet: archive/ contains no .md (retired agents disabled)"
fi

# F33/F3-5: trigger fixtures single source + real fixture (agents match CONTRACT, positives present)
if [[ -f tests/triggers.yml ]]; then
  note "fleet: tests/triggers.yml present"
  _t_agents="$(grep -E '^  - agent:' tests/triggers.yml | sed 's/^  - agent: *//' | sort)"
  _c_agents="$(printf '%s\n' "${CONTRACT_NAMES[@]}" | sort)"
  if [[ "$_t_agents" == "$_c_agents" ]]; then
    note "fleet: triggers.yml agents == CONTRACT"
  else
    fail "fleet: triggers.yml agents != CONTRACT"
  fi
  for _a in "${CONTRACT_NAMES[@]}"; do
    _blk="$(grep -A20 "^  - agent: $_a\$" tests/triggers.yml || true)"
    if printf '%s' "$_blk" | grep -qE '^    positive:' && printf '%s' "$_blk" | grep -qE '^      - '; then
      note "fleet: triggers fixtures for $_a present"
    else
      fail "fleet: triggers.yml missing positive fixture for $_a"
    fi
  done
else
  warn "fleet: tests/triggers.yml missing (F33)"
fi

# F18: e2e templates extracted
if [[ -f templates/playwright.config.ts.tmpl && -f templates/e2e.github-actions.yml.tmpl ]]; then
  note "fleet: e2e templates present"
else
  warn "fleet: e2e templates missing under templates/"
fi


# Model policy (D2 settled 2026-08-09): architect→opus; code-reviewer/security-reviewer/e2e-runner→sonnet.
check_model() {
  local name="$1" policy="$2" m
  m="$(get_field "$name.md" model)"
  case "$policy" in
    inherit)
      if [[ -z "$m" || "$m" == "inherit" ]]; then
        note "fleet: $name model=$m (inherit default)"
      else
        fail "fleet: $name model='$m' (expected inherit)"
      fi
      ;;
    opus)
      if [[ "$m" == "opus" ]]; then
        note "fleet: $name model=opus"
      else
        fail "fleet: $name model='$m' (expected opus)"
      fi
      ;;
    sonnet)
      if [[ "$m" == "sonnet" ]]; then
        note "fleet: $name model=sonnet"
      else
        fail "fleet: $name model='$m' (expected sonnet)"
      fi
      ;;
  esac
}
check_model architect opus
check_model code-reviewer sonnet
check_model security-reviewer sonnet
check_model e2e-runner sonnet

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
{
  printf '%s\n' "${LINES_OUT[@]}" | sort
  echo
  echo "==> result: $FAILS FAIL, $WARNS WARN (${#CONTRACT_NAMES[@]} agent files)"
}

if (( FAILS > 0 )); then
  exit 1
fi
if [[ "$STRICT" -eq 1 && "$WARNS" -gt 0 ]]; then
  echo "==> --strict: WARN treated as FAIL"
  exit 1
fi
exit 0
