#!/usr/bin/env bash
# pin-clis.sh — refresh or verify tools/cli-sha256 (ADR 0008).
#
# The wrapper refuses any agy/codex/grok whose SHA-256 does not match the pin.
# That is deliberate: if a binary is replaced without an explicit re-pin, the
# route fails closed instead of silently trusting the new bytes. This script is
# the explicit re-pin, and it is main-session-only — the fleet Bash gate admits
# agents only to tools/agent-cli.sh, never here.
#
# usage:
#   bash tools/pin-clis.sh           # rewrite the pin from the installed CLIs
#   bash tools/pin-clis.sh --check   # exit 1 if the pin is stale, write nothing
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PIN="${SCRIPT_DIR}/cli-sha256"
mode="${1:-}"
case "$mode" in
  ""|--check) ;;
  *) echo "usage: pin-clis.sh [--check]" >&2; exit 2 ;;
esac

tmp="$(mktemp "${TMPDIR:-/tmp}/cli-sha256.XXXXXX")" || exit 2
trap 'rm -f "$tmp"' EXIT

for backend in agy codex grok; do
  bin="$(bash -c "command -v $backend" 2>/dev/null)"
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    echo "pin-clis: $backend not found on PATH" >&2
    exit 127
  fi
  printf '%s %s\n' "$backend" "$(shasum -a 256 "$bin" | awk '{print $1}')"
done > "$tmp"

if [[ "$mode" == "--check" ]]; then
  if [[ ! -f "$PIN" ]]; then
    echo "pin-clis: pin file missing: $PIN" >&2
    exit 1
  fi
  if ! diff -q "$PIN" "$tmp" >/dev/null 2>&1; then
    echo "pin-clis: pin is stale — installed CLIs no longer match ${PIN}" >&2
    diff -u "$PIN" "$tmp" >&2 || true
    exit 1
  fi
  echo "pin-clis: ${PIN} matches the installed CLIs"
  exit 0
fi

mv "$tmp" "$PIN" || exit 2
trap - EXIT
echo "pin-clis: wrote ${PIN}"
cat "$PIN"
