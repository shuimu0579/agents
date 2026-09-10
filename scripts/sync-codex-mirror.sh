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

stale=0 written=0
while IFS='|' read -r name _tools _model _statuses _flag; do
  case "$name" in ''|\#*) continue ;; esac
  src="$FLEET_ROOT/$name.md"
  dst="$MIRROR_DIR/$name.toml"
  [[ -f "$src" ]] || { echo "sync-codex-mirror: missing source $src" >&2; exit 2; }

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if [[ ! -f "$dst" || "$dst" -ot "$src" ]]; then
      echo "STALE  $name  ($dst is older than $src)"
      stale=$((stale + 1))
    fi
    continue
  fi

  if [[ -f "$dst" && ! "$dst" -ot "$src" ]]; then
    continue
  fi

  python3 - "$src" "$dst" "$name" <<'PY' || { echo "sync-codex-mirror: failed to render $name" >&2; exit 2; }
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

# TOML basic multi-line strings process escapes, so backslashes and any embedded
# delimiter must be escaped or the mirror silently differs from the source.
def toml_ml(s):
    s = s.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
    return s

out = (
    f'name = "{name}"\n'
    f'description = """\n{toml_ml(desc)}\n"""\n\n'
    f'developer_instructions = """\n{toml_ml(body)}\n"""\n'
)
tmp = dst + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(out)
os.replace(tmp, dst)
PY
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
