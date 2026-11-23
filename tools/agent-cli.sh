#!/usr/bin/env bash
# agent-cli.sh — pinned external-CLI dispatcher for the 7-role fleet (ADR 0008).
#
# The fleet's Bash gate never admits agy/codex/grok directly: each of them is an
# agentic CLI that can write files and run commands, so a raw allowlist entry would
# be an arbitrary-execution grant. Instead the gate admits exactly one shape —
#   bash /Users/suimu/.claude/agents/tools/agent-cli.sh <role> <prompt words...>
# (or `bash tools/agent-cli.sh <role> <prompt words...>` when cwd is the fleet root)
# with `<role>` bound to the attributed caller, and this script owns the CLI, the
# model, and the safety flags. Agents cannot pass extra flags; there is no option
# passthrough.
#
# Role -> CLI mapping lives in hooks/lib/executor.sh (single source of truth).
# anthory defaults to agy Orchestrator (Neon); pullo has no mapping and runs on
# the host session model.
#
# Prompt: the remaining arguments are joined with spaces. With no arguments the
# prompt is read from bounded stdin (for the main session; agents cannot redirect).
# Both argv and stdin prompts are validated against option, slash-command, and
# subcommand shapes, and passed via each backend's explicit prompt channel.
#
# Exit: 0 CLI ran · 2 bad invocation / untrusted binary · 127 CLI missing
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FLEET_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
# Audit B3: the policy library is resolved from the wrapper's own location, never
# from an inherited environment variable.
LIB_DIR="${FLEET_ROOT}/hooks/lib"

if [[ ! -f "${LIB_DIR}/executor.sh" ]]; then
  echo "agent-cli: required policy library missing" >&2
  exit 2
fi
# shellcheck source=../hooks/lib/executor.sh
source "${LIB_DIR}/executor.sh"

usage() {
  cat >&2 <<EOF
usage: agent-cli.sh <role> <prompt words...>
roles: $(exec_agent_cli_roles)
EOF
}

role="${1:-}"
case "$role" in
  ""|-h|--help) usage; exit 2 ;;
esac
shift

# Any option-looking word is refused rather than treated as prompt text, so a
# CLI flag can never be smuggled through the prompt channel. Never echo the
# rejected argument value (audit #12).
for arg in "$@"; do
  case "$arg" in
    -*)
      echo "agent-cli: option-looking argument refused" >&2
      exit 2
      ;;
  esac
done

read_bounded_stdin() {
  command -v python3 >/dev/null 2>&1 || return 2
  python3 -I -c '
import os, select, sys, time
MAX = 65536
DEADLINE = 2.0
buf = bytearray()
start = time.monotonic()
try:
    fd = sys.stdin.fileno()
    os.fstat(fd)
except Exception:
    sys.exit(2)
while len(buf) <= MAX:
    remaining = DEADLINE - (time.monotonic() - start)
    if remaining <= 0:
        sys.exit(2)
    try:
        r, _, _ = select.select([fd], [], [], remaining)
    except OSError:
        sys.exit(2)
    if not r:
        sys.exit(2)
    try:
        chunk = os.read(fd, (MAX + 1) - len(buf))
    except OSError:
        sys.exit(2)
    if not chunk:
        break
    buf.extend(chunk)
if len(buf) > MAX or b"\x00" in buf:
    sys.exit(2)
try:
    text = buf.decode("utf-8")
except UnicodeDecodeError:
    sys.exit(2)
if not text.strip():
    sys.exit(3)
sys.stdout.write(text.rstrip("\r\n"))
' 2>/dev/null
}
prompt="$*"
if [[ $# -eq 0 ]]; then
  if [[ -t 0 ]]; then
    echo "agent-cli: no prompt given (arguments or stdin)" >&2
    exit 2
  fi
  if ! prompt="$(read_bounded_stdin)"; then
    case $? in
      3) echo "agent-cli: empty prompt" >&2 ;;
      *) echo "agent-cli: failed to read prompt from stdin" >&2 ;;
    esac
    exit 2
  fi
fi

# Bound the payload once; the hook already caps the command at 16384 bytes, and
# this keeps the prompt checks linear for the argv path too.
if [[ "${#prompt}" -gt 16384 ]]; then
  echo "agent-cli: prompt exceeds 16384 bytes" >&2
  exit 2
fi
if [[ -z "${prompt//[[:space:]]/}" ]]; then
  echo "agent-cli: empty prompt" >&2
  exit 2
fi

if ! exec_agent_cli_prompt_valid "$prompt"; then
  echo "agent-cli: option, slash-command, or blank prompt refused" >&2
  exit 2
fi

route=""
if ! route="$(exec_agent_cli_route "$role")"; then
  echo "agent-cli: role has no external CLI mapping (pullo runs on the host session model)" >&2
  exit 2
fi
cli="${route%%|*}"
model="${route#*|}"

# Resolve the target binary to a single physical path before exec.
# Refuse relative PATH entries, any world-writable or unexpectedly owned
# ancestor up to the first root-owned directory, and any binary inside
# agent-writable trees (the fleet tree, /tmp, /var/tmp). Location is not
# trust: tools/cli-sha256 pins the bytes, checked again immediately before exec.
resolve_cli_bin() {
  local name="$1" helper="${FLEET_ROOT}/hooks/lib/py/cli_resolve.py"
  command -v python3 >/dev/null 2>&1 || return 2
  [[ -f "$helper" ]] || return 2
  python3 -I "$helper" "$FLEET_ROOT" "$name" "${PATH:-}" "${HOME:-}"
}
# Re-check the selected binary and its hash immediately before exec.
# tools/cli-sha256 is under tools/, which the Write gate treats as
# agent-immutable by filesystem identity. A same-uid binary in ~/.local/bin
# is not trusted by location.
verify_cli_pin() {
  local name="$1" bin="$2" helper="${FLEET_ROOT}/hooks/lib/py/cli_verify_pin.py"
  command -v python3 >/dev/null 2>&1 || return 2
  [[ -f "$helper" ]] || return 2
  python3 -I "$helper" "${FLEET_CLI_PIN_FILE:-${SCRIPT_DIR}/cli-sha256}" "$name" "$bin" "$FLEET_ROOT"
}
cli_bin="$(resolve_cli_bin "$cli")"
resolve_rc=$?
if [[ "$resolve_rc" -eq 127 ]]; then
  echo "agent-cli: $cli not found" >&2
  exit 127
elif [[ "$resolve_rc" -ne 0 || -z "$cli_bin" ]]; then
  echo "agent-cli: refusing untrusted executable path for $cli" >&2
  exit 2
fi

# Last step before exec. Re-reads the pin and the binary bytes so a swap
# after resolution is still refused. The diagnostic names the file and both hashes.
if ! verify_cli_pin "$cli" "$cli_bin"; then
  exit 2
fi

# Non-interactive invocations using each backend's explicit prompt channel:
#   agy    --sandbox --disable-slash-commands --model <model> --print=<prompt>
#   codex  exec --ignore-user-config -s workspace-write -m <model> -c model_reasoning_effort="xhigh" - (prompt on stdin)
#   grok   --sandbox workspace --tools "read_file,grep,list_dir,write,search_replace" --model <model> -p <prompt>
case "$cli" in
  agy)
    exec "$cli_bin" --sandbox --disable-slash-commands --model "$model" "--print=$prompt"
    ;;
  codex)
    exec "$cli_bin" exec --ignore-user-config -s workspace-write -m "$model" -c model_reasoning_effort="xhigh" - <<< "$prompt"
    ;;
  grok)
    # Audit B11 / ADR 0010: pin the built-in tool set (read + workspace write) as
    # well as the workspace sandbox profile, so project settings cannot widen the tool pool.
    exec "$cli_bin" --sandbox workspace --tools "read_file,grep,list_dir,write,search_replace" --model "$model" -p "$prompt"
    ;;
esac
