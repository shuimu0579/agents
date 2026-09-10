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
REPO_OUTPUT_CONTRACT="$AGENTS_DIR/docs/agent-output-contract.md"
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

# frontmatter_block <file> -> only the leading, delimited YAML block.
frontmatter_block() {
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit 1; next }
    /^---[[:space:]]*$/ { closed = 1; exit }
    { print }
    END { if (!closed) exit 1 }
  ' "$1"
}

# Validate the fleet header format without adding a YAML dependency. Top-level
# keys are plain identifiers; only description supports indented scalar content.
# Reject unsupported syntax rather than let a YAML loader reinterpret authority.
frontmatter_valid() {
  awk '
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]/ {
      if (key != "description") {
        print "unsupported indented frontmatter outside description"; bad = 1
      }
      next
    }
    /^[A-Za-z_][A-Za-z0-9_-]*:([[:space:]]|$)/ {
      key = $0; sub(/:.*/, "", key)
      if (seen[key]++) { print "duplicate frontmatter key: " key; bad = 1 }
      next
    }
    { print "unsupported frontmatter syntax at header line " NR; bad = 1 }
    END { exit bad ? 1 : 0 }
  '
}

# get_field <validated-block> <field> -> scalar value; never reads the body.
get_field() {
  awk -v key="$2" 'index($0, key ":") == 1 {
    sub(/^[^:]*:[[:space:]]*/, ""); print; exit
  }' <<< "$1"
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

  if ! frontmatter="$(frontmatter_block "$f")"; then
    fail "$f: missing leading --- frontmatter block or closing delimiter"
    continue
  fi
  if ! frontmatter_error="$(frontmatter_valid <<< "$frontmatter")"; then
    fail "$f: $frontmatter_error"
    continue
  fi
  actual_name="$(get_field "$frontmatter" name)"
  actual_tools="$(get_field "$frontmatter" tools)"
  actual_model="$(get_field "$frontmatter" model)"

  # 1. frontmatter fields present
  # name + description: required; tools + model: optional per official schema (N7)
  for field in name description; do
    val="$(get_field "$frontmatter" "$field")"
    if [[ -z "$val" ]]; then fail "$f: missing required frontmatter field '$field'"; fi
  done
  if grep -qE '^tools:[[:space:]]*$' <<< "$frontmatter"; then
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
  # Check every report template (e.g. both critical-thinking modes), within its
  # own code fence. Instructions following the closing fence are not template text.
  if awk '
    /^```/ {
      if (fenced && $0 ~ /^```[[:space:]]*$/) {
        fenced = 0; verdict = 0; handoff = 0
      } else if (!fenced) {
        fenced = 1; handoff = 0
      } else if (verdict) { bad = 1 }
      next
    }
    verdict && $0 !~ /^[[:space:]]*$/ { bad = 1 }
    /^## Handoff([[:space:]]|$)/ { if (fenced) handoff = 1 }
    /^\*\*Verdict:\*\*/ {
      count++
      if (!fenced || !handoff ||
          $0 !~ /^\*\*Verdict:\*\* GO \| BLOCK \| NEEDS_INPUT[[:space:]]*$/) bad = 1
      verdict = 1
    }
    END { exit (bad || !count || verdict) ? 1 : 0 }
  ' "$f"; then
    note "$f: canonical Verdict ends each template after Handoff"
  else
    fail "$f: each **Verdict:** must be GO | BLOCK | NEEDS_INPUT, after ## Handoff, with only blanks before its closing code fence"
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
# Any Markdown file with a leading agent header is a candidate, regardless of
# directory. Ordinary documentation and embedded YAML examples are not agents.
DISCOVERED=()
while IFS= read -r -d '' f; do
  base="${f#./}"; base="${base%.md}"
  if header="$(frontmatter_block "$f")" && awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /[^[:space:]]/); indent = RSTART
      if (!minimum || indent < minimum) minimum = indent
      if (!index($0, ":")) next
      key = $0; sub(/^[[:space:]]*/, "", key); sub(/:.*/, "", key)
      sub(/[[:space:]]*$/, "", key)
      if (key == "name" || key == "\"name\"" || key == "\047name\047") names[indent] = 1
      if (key == "description" || key == "\"description\"" || key == "\047description\047") descriptions[indent] = 1
    }
    END { exit (names[minimum] && descriptions[minimum]) ? 0 : 1 }
  ' <<< "$header"; then
    DISCOVERED+=("$base")
  fi
done < <(find . -path './.git' -prune -o -name '*.md' -print0)

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
  if [[ ! -f "$REPO_OUTPUT_CONTRACT" ]]; then
    fail "fleet: missing checked-out output contract docs/agent-output-contract.md"
  elif cmp -s "$OUTPUT_CONTRACT_FIXTURE" "$REPO_OUTPUT_CONTRACT"; then
    note "fleet: checked-out output contract == vendored fixture"
  else
    fail "fleet: checked-out output contract drifted from tests/fixtures/output-contract.md"
  fi
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
    note "fleet: installed output contract absent; checked-out contract validated against fixture"
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
