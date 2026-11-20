#!/usr/bin/env bash
#
# grok-hooks-registration.test.sh — asserts the Grok hook registration file
# registers all four fleet gates with the expected matchers, timeouts and
# failClosed setting. Skips when the file is absent, because a machine that
# never uses Grok has no registration to check.
#
# Override the path with GROK_GATES for tests and alternate hosts.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
GROK_GATES="${GROK_GATES:-$HOME/.grok/hooks/agent-gates.json}"

echo "==> Grok hook registration ($GROK_GATES)"

if [ ! -f "$GROK_GATES" ]; then
  echo "    skip: registration file absent (no Grok on this machine)"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 required for grok-hooks-registration.test.sh" >&2
  exit 2
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL  $1" >&2; }

# The python helper emits "ok<TAB>message" or "bad<TAB>message" per assertion.
# Bash 3.2 misparses a heredoc inside process substitution, so collect first.
RESULTS="$(
python3 -I - "$GROK_GATES" "$REPO_ROOT" <<'PY'
import json
import os
import sys

path, repo = sys.argv[1], sys.argv[2]
try:
    doc = json.load(open(path, encoding="utf-8"))
except Exception as exc:  # noqa: BLE001 - reported as a test failure
    print(f"bad\tregistration is not valid JSON: {exc}")
    raise SystemExit(0)

hooks = doc.get("hooks")
if not isinstance(hooks, dict):
    print("bad\tregistration has no top-level hooks object")
    raise SystemExit(0)

def groups(event):
    value = hooks.get(event, [])
    return value if isinstance(value, list) else []

def entries(event):
    for group in groups(event):
        if not isinstance(group, dict):
            continue
        matcher = group.get("matcher", "")
        for hook in group.get("hooks", []) or []:
            if isinstance(hook, dict):
                yield matcher, hook

def names(matcher):
    return {part.strip() for part in str(matcher).split("|") if part.strip()}

def command(hook):
    return hook.get("command", "")

def report(ok, message):
    print(("ok" if ok else "bad") + "\t" + message)

def find(event, script):
    hits = []
    for matcher, hook in entries(event):
        cmd = command(hook)
        if cmd == script or cmd.endswith("/" + script):
            hits.append((matcher, hook))
    return hits

expected = [
    ("PreToolUse", "restrict-bash-by-agent.sh", 5),
    ("PreToolUse", "restrict-mutator-write.sh", 5),
    ("PreToolUse", "xixi/restrict-write.sh", 5),
    ("PostToolUse", "xixi/copy-on-write.sh", 15),
]

for event, script, timeout in expected:
    hits = find(event, script)
    report(len(hits) == 1, f"{event} registers {script} exactly once")
    if len(hits) != 1:
        continue
    matcher, hook = hits[0]
    report(hook.get("timeout") == timeout,
           f"{script} timeout is {timeout} (got {hook.get('timeout')!r})")
    report(os.path.isabs(command(hook)), f"{script} command is an absolute path")
    if event == "PreToolUse":
        report(hook.get("failClosed") is True,
               f"{script} sets failClosed true")

bash_matcher = find("PreToolUse", "restrict-bash-by-agent.sh")
if len(bash_matcher) == 1:
    report("Bash" in names(bash_matcher[0][0]),
           "Bash gate matcher includes the Bash alias")

for script in ("restrict-mutator-write.sh", "xixi/restrict-write.sh"):
    hits = find("PreToolUse", script)
    if len(hits) == 1:
        report({"Write", "write"} <= names(hits[0][0]),
               f"{script} matcher covers both Write and write")

copy = find("PostToolUse", "xixi/copy-on-write.sh")
if len(copy) == 1:
    report({"Write", "write"} <= names(copy[0][0]),
           "copy-on-write matcher covers both Write and write")

PY
)"

while IFS=$'\t' read -r verdict message; do
  case "$verdict" in
    ok)  pass "$message" ;;
    bad) fail "$message" ;;
  esac
done <<< "$RESULTS"

echo
echo "==> result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
