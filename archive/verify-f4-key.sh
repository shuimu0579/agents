#!/usr/bin/env bash
# verify-f4-key.sh — post-rotation check for grill F4 (no secret values printed).
set -euo pipefail

ok()   { echo "OK    $1"; }
warn() { echo "WARN  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
FAILS=0

echo "==> F4 key rotation verification"

# 1. settings.json must not embed the key
if grep -q 'ANTHROPIC_API_KEY' "${HOME}/.claude/settings.json" 2>/dev/null; then
  fail "settings.json still contains ANTHROPIC_API_KEY"
else
  ok "settings.json has no ANTHROPIC_API_KEY"
fi

# 2. secrets file present + mode
SEC="${HOME}/.config/secrets/anthropic.env"
if [[ ! -f "$SEC" ]]; then
  fail "missing $SEC — create it with ANTHROPIC_API_KEY=<new key> and chmod 600"
elif [[ ! -r "$SEC" ]]; then
  fail "$SEC not readable"
else
  mode=$(stat -f '%Lp' "$SEC" 2>/dev/null || stat -c '%a' "$SEC" 2>/dev/null || echo '?')
  if [[ "$mode" == "600" || "$mode" == "400" ]]; then
    ok "secrets file mode=$mode"
  else
    warn "secrets file mode=$mode (prefer 600); run: chmod 600 $SEC"
  fi
  if grep -qE '^[[:space:]]*ANTHROPIC_API_KEY=.' "$SEC"; then
    ok "secrets file defines ANTHROPIC_API_KEY"
  else
    fail "secrets file has empty or missing ANTHROPIC_API_KEY="
  fi
fi

# 3. env loaded from secrets via zshrc — must NOT inherit parent process env
#    (this Grok/Claude session may still hold the old key in its environment).
loaded=$(
  env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
    TERM="${TERM:-dumb}" \
    /bin/zsh -lc 'printf %s "${ANTHROPIC_API_KEY:-}"' 2>/dev/null || true
)
if [[ -z "$loaded" ]]; then
  fail "clean zsh has no ANTHROPIC_API_KEY — write $SEC then re-run"
else
  ok "clean zsh loads ANTHROPIC_API_KEY via secrets/zshrc"
  # Shape heuristic without printing secret material (old key was len 49 + prefix 695a)
  if [[ "${#loaded}" -eq 49 && "${loaded:0:4}" == "695a" ]]; then
    fail "loaded key still matches OLD exposed fingerprint shape — revoke+replace not done"
  else
    ok "loaded key does not match known old fingerprint shape"
  fi
fi

# 4. current process may still hold the old env until restart
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  cur="$ANTHROPIC_API_KEY"
  if [[ "${#cur}" -eq 49 && "${cur:0:4}" == "695a" ]]; then
    warn "THIS shell still has the old-shaped key in env — restart Grok/Claude/terminal after rotation"
  else
    ok "current shell key shape looks rotated (len=${#cur})"
  fi
else
  warn "current shell has no ANTHROPIC_API_KEY (ok if you only use clean logins)"
fi

echo
if (( FAILS > 0 )); then
  echo "==> result: $FAILS FAIL — rotation incomplete"
  exit 1
fi
echo "==> result: F4 local checks PASS — confirm old key is revoked in BigModel console"
exit 0
