#!/usr/bin/env bash
# copy-prompt.sh — copy stdin to the system clipboard (cross-platform)
# Used by the _xixi subagent. Reads the refined prompt from stdin; takes no args.
# Exit 0 on success, non-zero if no clipboard backend is available.
set -euo pipefail

if   command -v pbcopy  >/dev/null 2>&1; then exec pbcopy
elif command -v wl-copy >/dev/null 2>&1; then exec wl-copy
elif command -v xclip   >/dev/null 2>&1; then exec xclip -selection clipboard
else
  echo "copy-prompt.sh: no clipboard backend found (pbcopy / wl-copy / xclip)" >&2
  exit 1
fi
