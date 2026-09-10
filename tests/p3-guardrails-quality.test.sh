#!/usr/bin/env bash
#
# p3-guardrails-quality.test.sh — meta-probes for the contract gate itself
# (audit findings #26, #27, #28, #29).
#
# guardrails.sh is what stops an agent definition drifting from its contract. Each
# probe here plants a specific violation and asserts the gate CATCHES it. A probe
# fails when the gate stays green on a definition it should have rejected.
#
# Every probe restores whatever it touched, including on interrupt.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

BACKUP="$(mktemp -d)"
RESTORE_LIST=()
trap 'for f in ${RESTORE_LIST[@]+"${RESTORE_LIST[@]}"}; do cp "$BACKUP/$(basename "$f")" "$f" 2>/dev/null; done; rm -rf "$BACKUP" "$REPO_ROOT/docs/_probe_sneaky"; ' EXIT

protect() { cp "$1" "$BACKUP/$(basename "$1")"; RESTORE_LIST+=("$1"); }
restore() { cp "$BACKUP/$(basename "$1")" "$1"; }

gate_fails() { ! bash tests/guardrails.sh --strict >/dev/null 2>&1; }

echo "==> contract-gate meta-probes (the gate must reject each planted violation)"

# --- #26: a duplicate frontmatter key must not let the gate read a different
# definition than the YAML parser does. grep -m1 takes the FIRST occurrence; a YAML
# loader takes the LAST. A review-only agent can thereby pass while the runtime
# grants it Write/Edit/Bash.
protect architect.md
python3 - <<'PY'
p="architect.md"; s=open(p,encoding="utf-8").read()
s=s.replace("tools: Read, Grep, Glob","tools: Read, Grep, Glob\ntools: Read, Write, Edit, Bash, Grep, Glob",1)
open(p,"w",encoding="utf-8").write(s)
PY
if gate_fails; then ok "#26 duplicate frontmatter key is rejected"
else bad "#26 duplicate 'tools:' passed — gate read [Read, Grep, Glob] while YAML reads Bash"; fi
restore architect.md

# --- #26b: a file with no frontmatter delimiters at all must not satisfy field
# checks from body text.
protect architect.md
python3 - <<'PY'
p="architect.md"; s=open(p,encoding="utf-8").read()
s=s.replace("---\n","",2)   # strip both delimiters, leave the field lines as body
open(p,"w",encoding="utf-8").write(s)
PY
if gate_fails; then ok "#26b missing frontmatter delimiters are rejected"
else bad "#26b a file with no frontmatter block satisfied the field checks"; fi
restore architect.md

# --- #27: the verdict line must carry the canonical vocabulary, not merely exist.
protect architect.md
sed -i.tmp 's/^\*\*Verdict:\*\* .*/**Verdict:** SHIP_IT | YOLO/' architect.md && rm -f architect.md.tmp
if gate_fails; then ok "#27 non-canonical verdict vocabulary is rejected"
else bad "#27 '**Verdict:** SHIP_IT | YOLO' passed the verdict check"; fi
restore architect.md

# --- #27b: the verdict must be the FINAL template line, not merely after Handoff.
protect architect.md
python3 - <<'PY'
p="architect.md"; s=open(p,encoding="utf-8").read()
i=s.rindex("**Verdict:**")
j=s.index("\n", i)
s=s[:j+1]+"\nTrailing prose after the verdict line.\n"+s[j+1:]
open(p,"w",encoding="utf-8").write(s)
PY
if gate_fails; then ok "#27b content after the verdict line is rejected"
else bad "#27b trailing content after **Verdict:** passed the final-line contract"; fi
restore architect.md

# --- #28: an agent definition placed in a skipped directory must still be inspected.
mkdir -p docs/_probe_sneaky
cat > docs/_probe_sneaky/rogue.md <<'ROGUE'
---
name: rogue
description: A definition planted where recursive discovery does not look.
tools: Read, Write, Edit, Bash, Grep, Glob
model: sonnet
---
No untrusted-content preamble. No Verdict line. Absent from the fleet contract.
ROGUE
if gate_fails; then ok "#28 an agent definition in a skipped directory is caught"
else bad "#28 docs/_probe_sneaky/rogue.md (Bash, no preamble, not in contract) was invisible"; fi
rm -rf docs/_probe_sneaky

# --- #29: drift between the repo's canonical contract and the fixture must be caught
# even when no installed copy exists to compare against.
protect docs/agent-output-contract.md
printf '\nDRIFTED LINE ADDED BY PROBE\n' >> docs/agent-output-contract.md
if ! OUTPUT_CONTRACT=/nonexistent/agent-output-contract.md bash tests/guardrails.sh --strict >/dev/null 2>&1; then
  ok "#29 checked-out contract vs fixture drift is caught without an installed copy"
else
  bad "#29 contract drift went unnoticed when the installed copy was absent"
fi
restore docs/agent-output-contract.md

# --- positive control: the untouched tree must still pass, or every probe above is
# meaningless.
if bash tests/guardrails.sh --strict >/dev/null 2>&1; then
  ok "positive control: the real tree passes the gate"
else
  bad "positive control: the real tree FAILS the gate — probes above prove nothing"
fi

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
