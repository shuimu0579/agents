#!/usr/bin/env bash
# sync-codex-mirror.sh — regenerate ~/.codex/agents/*.toml from this repo's agent .md files.
#
# Claude Code auto-loads the .md files directly; Codex reads a generated TOML mirror.
# Without this script the two runtimes drift, and a security decision applied to the
# .md (e.g. ADR 0002 removing Bash from e2e-runner) silently does not reach Codex.
#
# Usage:
#   bash scripts/sync-codex-mirror.sh          # regenerate stale mirrors
#   bash scripts/sync-codex-mirror.sh --check  # exit 1 if any mirror is stale (CI/guardrails)
set -uo pipefail

FLEET_ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MIRROR_DIR="${CODEX_AGENTS_DIR:-$HOME/.codex/agents}"
CONTRACT="${AGENT_CONTRACT_FILE:-$FLEET_ROOT/tests/fixtures/agent-contract.tsv}"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

if [[ ! -r "$CONTRACT" ]]; then
  echo "sync-codex-mirror: fleet contract unreadable at $CONTRACT" >&2
  exit 2
fi

if [[ ! -d "$MIRROR_DIR" ]]; then
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "sync-codex-mirror: no mirror directory at $MIRROR_DIR — nothing to check"
    exit 0
  fi
  mkdir -p "$MIRROR_DIR" || { echo "sync-codex-mirror: cannot create $MIRROR_DIR" >&2; exit 2; }
fi

render_mirror() {
  # $1 source .md, $2 destination .toml, $3 agent name
  python3 - "$1" "$2" "$3" <<'PY'
import sys, re, os
src, dst, name = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read()

m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
if not m:
    sys.exit(f"{src}: no YAML frontmatter")
fm, body = m.group(1), m.group(2).lstrip("\n")

dm = re.search(r"^description:\s*\|\s*\n(.*?)(?=^\w+:|\Z)", fm, re.S | re.M)
if dm:
    raw = dm.group(1)
    indent = min((len(l) - len(l.lstrip()) for l in raw.splitlines() if l.strip()), default=0)
    desc = "\n".join(l[indent:] if len(l) >= indent else l for l in raw.splitlines()).strip()
else:
    dm = re.search(r"^description:\s*(.+)$", fm, re.M)
    desc = dm.group(1).strip() if dm else ""

# TOML LITERAL multi-line strings ('\'\'\'') process no escapes at all, which is what
# agent bodies need: they contain backslash sequences such as \\n inside example
# prompts, and a basic ("""...""") string would require escaping them — silently
# changing the text the agent actually receives. Fall back to a basic string only when
# the content itself contains the literal delimiter.
def emit(value):
    if "'" * 3 not in value and not value.endswith("'"):
        return "'" * 3 + "\n" + value + "\n" + "'" * 3
    escaped = value.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
    return '"""\n' + escaped + '\n"""'

out = (
    f'name = "{name}"\n'
    f'description = {emit(desc)}\n\n'
    f'developer_instructions = {emit(body)}\n'
)
tmp = dst + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(out)
os.replace(tmp, dst)
PY
}

mirror_current() {
  local src_f="$1" dst_f="$2" name_f="$3" tmp rc
  [[ -f "$dst_f" ]] || return 1
  tmp="$(mktemp)" || return 1
  if ! render_mirror "$src_f" "$tmp" "$name_f" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  cmp -s "$tmp" "$dst_f"; rc=$?
  rm -f "$tmp"
  return $rc
}

stale=0 written=0
while IFS='|' read -r name _tools _model _statuses _flag; do
  case "$name" in ''|\#*) continue ;; esac
  src="$FLEET_ROOT/$name.md"
  dst="$MIRROR_DIR/$name.toml"
  [[ -f "$src" ]] || { echo "sync-codex-mirror: missing source $src" >&2; exit 2; }

  # Compare CONTENT, not mtime: a test that edits a definition and restores it bumps
  # the mtime without changing a byte, and an mtime-only check then calls a mirror
  # stale when it is byte-identical to what would be generated.
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if ! mirror_current "$src" "$dst" "$name"; then
      echo "STALE  $name  ($dst differs from what $src would generate)"
      stale=$((stale + 1))
    fi
    continue
  fi

  if mirror_current "$src" "$dst" "$name"; then
    continue
  fi

  render_mirror "$src" "$dst" "$name" || { echo "sync-codex-mirror: failed to render $name" >&2; exit 2; }
  echo "wrote  $name"
  written=$((written + 1))
done < "$CONTRACT"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  if [[ "$stale" -gt 0 ]]; then
    echo "sync-codex-mirror: $stale mirror(s) stale — run: bash scripts/sync-codex-mirror.sh" >&2
    exit 1
  fi
  echo "sync-codex-mirror: all mirrors current"
  exit 0
fi

echo "sync-codex-mirror: $written regenerated"
