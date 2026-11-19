#!/usr/bin/env bash
# create-approval.sh — mint a one-shot approval token for a privileged agent command.
#
# Orchestrator-only. An agent cannot mint its own approval: the Write/Edit gate denies
# every write under hooks/approvals/ unconditionally (rule:approvals).
#
# Usage:
#   scripts/create-approval.sh <with-deps|snapshots> <session-id>
#
# The token binds the session and the repository it was minted for (audit #21). An
# empty file is no longer accepted — a token that names nothing authorizes anything,
# and a concurrent session could consume one intended for another.
set -uo pipefail

usage() { echo "usage: $0 <with-deps|snapshots> <session-id>" >&2; exit 2; }

NAME="${1:-}"; SESSION="${2:-}"
[ -n "$NAME" ] && [ -n "$SESSION" ] || usage
case "$NAME" in
  with-deps|snapshots) ;;
  *) echo "create-approval: unknown approval '$NAME'" >&2; usage ;;
esac
case "$SESSION" in
  *[!A-Za-z0-9_.:-]*|"") echo "create-approval: session id has unexpected characters" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FLEET_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
APPROVAL_DIR="${APPROVAL_DIR:-$FLEET_ROOT/hooks/approvals}"

[ -d "$APPROVAL_DIR" ] || { echo "create-approval: no approval dir at $APPROVAL_DIR" >&2; exit 2; }

TOKEN="$APPROVAL_DIR/$NAME"
if [ -e "$TOKEN" ] || [ -L "$TOKEN" ]; then
  echo "create-approval: $NAME already pending — consume or remove it first" >&2
  exit 2
fi

# Exclusive create so two orchestrators cannot both believe they minted it.
if ! ( set -o noclobber; : > "$TOKEN" ) 2>/dev/null; then
  echo "create-approval: could not exclusively create $TOKEN" >&2
  exit 2
fi
chmod 600 "$TOKEN" || { rm -f -- "$TOKEN"; exit 2; }

{
  printf 'session=%s\n' "$SESSION"
  printf 'repo=%s\n'    "$FLEET_ROOT"
} > "$TOKEN" || { rm -f -- "$TOKEN"; exit 2; }

echo "create-approval: minted $NAME for session=$SESSION repo=$FLEET_ROOT (one-shot, max age 300s)"
