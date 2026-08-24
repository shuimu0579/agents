#!/usr/bin/env bash
# security.sh — Security Checks, URL Parsing, Command Sanitization, and Approval Gates
# Sourced by fleet hooks.
# No `set -e`: PreToolUse exit 1 is fail-open. Callers choose errexit.
set -uo pipefail

if ! declare -F fs_get_mode >/dev/null 2>&1; then
  # shellcheck source=fs.sh
  source "$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fs.sh"
fi

# Normalize command: compact whitespace
sec_cmd_normalize() {
  local cmd="$1"
  printf '%s' "$cmd" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//;s/[[:space:]]+/ /g'
}

# Check if normalized command contains forbidden shell operators or substitutions
sec_cmd_has_shell_meta() {
  local norm="$1"
  if printf '%s' "$norm" | grep -qE '[;&|<>`$(){}]|&&|\|\||\$\(|`|\n|\r'; then
    return 0
  fi
  if printf '%s' "$norm" | grep -qE '\\;|\\\||\\&'; then
    return 0
  fi
  return 1
}

# Check if command is on the destructive denylist
sec_cmd_is_destructive() {
  local norm="$1"
  printf '%s' "$norm" | grep -qiE \
    '^(rm[[:space:]]+-rf|git[[:space:]]+push|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+clean[[:space:]]+-fd|chmod[[:space:]]+777|dd[[:space:]]+|mkfs)'
}

# Check if command attempts network egress, shell escape, or interpreter inline execution
sec_cmd_is_network_or_escape() {
  local norm="$1"
  printf '%s' "$norm" | grep -qiE \
    '(^|[[:space:]])(curl|wget|nc|ncat|fetch)([[:space:]]|$)|/dev/tcp|(^|[[:space:]])(bash|sh)[[:space:]]+-c|(^|[[:space:]])eval[[:space:]]|(^|[[:space:]])(python3?|perl|ruby)[[:space:]]+-e|(^|[[:space:]])node[[:space:]]+-e'
}

# Check if command attempts package installation
sec_cmd_is_package_install() {
  local norm="$1"
  printf '%s' "$norm" | grep -qiE \
    '(^|[[:space:]])(npm|yarn|pnpm|bun)[[:space:]]+(install|add|i)([[:space:]]|$)'
}

# Parse URL authority into its exact lowercase host. Handles scheme, protocol-relative //,
# userinfo, host:port, and bracketed IPv6.
sec_url_extract_host() {
  local u="${1}" authority host
  u="${u#*://}"              # strip scheme+:// if present
  u="${u#//}"                # strip protocol-relative //
  authority="${u%%[/?#]*}"   # isolate authority from path/query/fragment
  authority="${authority##*@}" # strip userinfo through the final @

  if [[ "$authority" == \[* ]]; then
    if [[ "$authority" =~ ^\[([^]]+)\](:[0-9]+)?$ ]]; then
      host="${BASH_REMATCH[1]}"
    else
      host=""
    fi
  elif [[ "$authority" =~ ^([^:]+):[0-9]+$ ]]; then
    host="${BASH_REMATCH[1]}"
  else
    host="$authority"
  fi
  host="${host%.}"
  printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

# Check if target host is safe (local/test/staging allowlist)
sec_is_host_safe() {
  local host="$1" allowed_hosts_csv="${2:-}" candidate
  case "$host" in
    localhost|127.0.0.1|::1) return 0 ;;
    *.test|*.local) return 0 ;;
  esac
  [[ -n "$allowed_hosts_csv" ]] || return 1
  local -a allowed_hosts
  IFS=',' read -ra allowed_hosts <<< "$allowed_hosts_csv"
  for candidate in "${allowed_hosts[@]}"; do
    candidate="$(printf '%s' "$candidate" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
    [[ -n "$candidate" && "$candidate" == "$host" ]] && return 0
  done
  return 1
}

# Atomically consume a one-shot approval file (e.g. with-deps, snapshots)
sec_consume_approval() {
  local approval_dir="$1" name="$2" max_age_sec="${3:-300}"
  local f claim mode now mtime age
  f="${approval_dir}/${name}"
  if [[ ! -f "$f" ]]; then
    return 1
  fi
  claim="${f}.consuming.$$"
  if ! mv -- "$f" "$claim" 2>/dev/null; then
    return 1
  fi

  mode=$(fs_get_mode "$claim")
  if [[ "$mode" != "600" ]]; then
    rm -f -- "$claim" 2>/dev/null || true
    return 1
  fi

  if ! now=$(date +%s 2>/dev/null); then
    rm -f -- "$claim" 2>/dev/null || true
    return 1
  fi

  mtime=$(fs_get_mtime "$claim")
  age=$((now - mtime))
  if [[ "$mtime" -eq 0 || "$age" -lt 0 || "$age" -ge "$max_age_sec" ]]; then
    rm -f -- "$claim" 2>/dev/null || true
    return 1
  fi

  rm -f -- "$claim" 2>/dev/null || true
  return 0
}
