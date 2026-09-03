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
AGENT_CONTRACT_FILE="$SCRIPT_DIR/fixtures/agent-contract.tsv"
OUTPUT_CONTRACT_FIXTURE="$SCRIPT_DIR/fixtures/output-contract.md"
LIVE_OUTPUT_CONTRACT="${OUTPUT_CONTRACT:-$HOME/.claude/agents/docs/agent-output-contract.md}"
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

# status_sets_equal <actual-pipe-list> <expected-semicolon-list>
status_sets_equal() {
  local actual expected
  actual="$(printf '%s' "$1" | tr '|' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort)"
  expected="$(printf '%s' "$2" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort)"
  [[ "$actual" == "$expected" ]]
}

# ---------------------------------------------------------------------------
# Contract fixture — the single source of truth for agents and the Bash hook.
#   name|expected_tools|model|domain_statuses(;)|flag
#   flag: review_only | mutator
# ---------------------------------------------------------------------------
if [[ -f "$AGENT_CONTRACT_FILE" ]]; then
  CONTRACT="$(grep -vE '^[[:space:]]*(#|$)' "$AGENT_CONTRACT_FILE" || true)"
else
  CONTRACT=""
  fail "fleet: missing agent contract fixture $AGENT_CONTRACT_FILE"
fi

echo "==> guardrails: auditing $AGENTS_DIR"

while IFS='|' read -r name exp_tools exp_model domain_statuses flag; do
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
  if grep -qE '^tools:[[:space:]]*$' "$f"; then
    fail "$f: YAML-block tools are unsupported; use a comma string or JSON array (fail-closed)"
  elif [[ -z "$actual_tools" ]]; then
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
  if [[ -n "$actual_model" && "$actual_model" != "$exp_model" ]]; then
    fail "$f: model '$actual_model' != expected '$exp_model'"
  else
    note "$f: model == $exp_model"
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

  # 4. Parse the actual Domain status template line; whole-file token mentions do not count.
  domain_line="$(grep -m1 '^\*\*Domain status:\*\*' "$f" | sed 's/^\*\*Domain status:\*\*[[:space:]]*//' || true)"
  if [[ -z "$domain_line" ]]; then
    fail "$f: missing **Domain status:** template line"
  elif status_sets_equal "$domain_line" "$domain_statuses"; then
    note "$f: Domain status tokens exactly match [$domain_statuses]"
  else
    fail "$f: Domain status tokens '$domain_line' != expected '$domain_statuses'"
  fi

  # 4b. canonical orchestrator Verdict (grill F14) — every agent must emit GO|BLOCK|NEEDS_INPUT vocabulary
  if token_present "$f" "**Verdict:**"; then
    note "$f: canonical Verdict line present"
  else
    fail "$f: missing canonical **Verdict:** (bold, GO|BLOCK|NEEDS_INPUT) — see docs/agent-output-contract.md"
  fi

  # 4b2. Verdict must be the final template line, after ## Handoff (contract: final line) — D-TOKEN freeze
  _hln="$(grep -n '^## Handoff' "$f" | head -1 | cut -d: -f1 || true)"
  _vln="$(grep -n '^\*\*Verdict:\*\*' "$f" | head -1 | cut -d: -f1 || true)"
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

# F10: quarantine instructions require an issue and explicit ISO expiry; reject
# any concrete active-agent expiry that is today or earlier.
if token_present e2e-runner.md "Issue #N; expires YYYY-MM-DD"; then
  note "e2e-runner.md: quarantine token requires issue + expiry"
else
  fail "e2e-runner.md: quarantine fixme must use 'Issue #N; expires YYYY-MM-DD'"
fi
_today="$(date +%F)"
while IFS= read -r _expiry_token; do
  [[ -z "$_expiry_token" ]] && continue
  _expiry="${_expiry_token##*expires }"
  if [[ "$_expiry" < "$_today" || "$_expiry" == "$_today" ]]; then
    fail "fleet: expired quarantine token '$_expiry_token'"
  fi
done < <(grep -hoE 'Issue #[0-9]+; expires [0-9]{4}-[0-9]{2}-[0-9]{2}' ./*.md 2>/dev/null || true)

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
    ./CLAUDE.md|./AGENTS.md|./archive/*|./docs/*|./tests/*|./templates/*|./scripts/*|./hooks/*|./.github/*|./.git/*|./.claude/*|./grill-report-*|./codex-*) continue ;;
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

# F14: every root Markdown file except CLAUDE.md and AGENTS.md is an active agent and must be
# represented in the contract, even if it lacks recognizable frontmatter.
for f in ./*.md; do
  [[ "$f" == "./CLAUDE.md" || "$f" == "./AGENTS.md" ]] && continue
  root_name="${f#./}"; root_name="${root_name%.md}"
  found=0
  for c in "${CONTRACT_NAMES[@]}"; do [[ "$c" == "$root_name" ]] && found=1 && break; done
  if [[ "$found" -eq 0 ]]; then fail "fleet: root Markdown $f is not in CONTRACT"; fi
done

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

# F18: e2e templates extracted
if [[ -f templates/playwright.config.ts.tmpl && -f templates/e2e.github-actions.yml.tmpl ]]; then
  note "fleet: e2e templates present"
else
  warn "fleet: e2e templates missing under templates/"
fi

# F5: the hook must consume the same tracked contract fixture as guardrails.
if grep -qF '../tests/fixtures/agent-contract.tsv' hooks/restrict-bash-by-agent.sh; then
  note "fleet: Bash hook and guardrails share agent-contract.tsv"
else
  fail "fleet: Bash hook is not coupled to tests/fixtures/agent-contract.tsv"
fi

# F16/F19/F23: CI validates the vendored output contract; local runs additionally
# require the installed contract to be byte-identical when it exists.
if [[ ! -f "$OUTPUT_CONTRACT_FIXTURE" ]]; then
  fail "fleet: missing vendored output contract fixture"
else
  note "fleet: vendored output contract fixture present"
  while IFS='|' read -r name _tools _model domain_statuses _flag; do
    IFS=';' read -ra toks <<< "$domain_statuses"
    for t in "${toks[@]}"; do
      # Accept bare or backtick-wrapped domain tokens (live contract uses `TOKEN`).
      if grep -qF "| $name | $t |" "$OUTPUT_CONTRACT_FIXTURE" \
        || grep -qF "| $name | \`$t\` |" "$OUTPUT_CONTRACT_FIXTURE"; then
        note "fleet: output contract maps $name/$t"
      else
        fail "fleet: output contract missing exact row for $name/$t"
      fi
    done
  done <<< "$CONTRACT"
  if [[ -f "$LIVE_OUTPUT_CONTRACT" ]]; then
    if cmp -s "$OUTPUT_CONTRACT_FIXTURE" "$LIVE_OUTPUT_CONTRACT"; then
      note "fleet: installed output contract == vendored fixture"
    else
      fail "fleet: installed output contract drifted from tests/fixtures/output-contract.md"
    fi
  else
    note "fleet: installed output contract absent; vendored fixture is CI authority"
  fi
fi

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
