#!/usr/bin/env bash
# security.sh — Security Checks, URL Parsing, Command Sanitization, and Approval Gates
# Sourced by fleet hooks.
# No `set -e`: PreToolUse exit 1 is fail-open. Callers choose errexit.
set -uo pipefail

if ! declare -F fs_get_mode >/dev/null 2>&1; then
  # shellcheck source=fs.sh
  source "$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fs.sh"
fi

# Parse ONE simple Bash command without executing it. SEC_ARGV is the only
# command representation policy callers may use. No eval, re-joining, or second
# round of quote removal. Unsupported shell syntax fails closed.
sec_cmd_tokenize() {
  local text="$1" state=plain word="" started=0 c next i
  local pattern="" glob=0
  SEC_ARGV=()
  for ((i=0; i<${#text}; i++)); do
    c="${text:i:1}"
    # Keep the existing prohibition even for quoted/escaped shell operators.
    case "$c" in
      $'\n'|$'\r'|';'|'&'|'|'|'<'|'>'|'`'|'$'|'('|')'|'{'|'}') return 1 ;;
    esac
    case "$state" in
      single)
        if [[ "$c" == "'" ]]; then state=plain
        else word+="$c"; pattern+="\\$c"; fi
        ;;
      double)
        case "$c" in
          '"') state=plain ;;
          '\')
            ((i + 1 < ${#text})) || return 1
            next="${text:i+1:1}"
            # Inside double quotes Bash removes backslashes only before these
            # characters (dollar/backtick/newline are rejected on the next pass).
            case "$next" in
              '"'|'\') word+="$next"; pattern+="\\$next"; i=$((i + 1)) ;;
              *) word+='\'; pattern+='\\' ;;
            esac
            ;;
          *) word+="$c"; pattern+="\\$c" ;;
        esac
        ;;
      plain)
        case "$c" in
          ' '|$'\t')
            if [[ "$started" -eq 1 ]]; then
              # Unmatched Bash glob syntax is literal; any possible pathname
              # expansion is refused instead of inspecting different argv.
              if [[ "$glob" -eq 1 ]] && compgen -G "$pattern" >/dev/null; then return 1; fi
              SEC_ARGV+=("$word")
            fi
            word=""; pattern=""; glob=0; started=0
            ;;
          "'") state=single; started=1 ;;
          '"') state=double; started=1 ;;
          '\')
            ((i + 1 < ${#text})) || return 1
            next="${text:i+1:1}"
            case "$next" in
              $'\n'|$'\r'|';'|'&'|'|'|'<'|'>'|'`'|'$'|'('|')'|'{'|'}') return 1 ;;
            esac
            word+="$next"; pattern+="\\$next"; started=1; i=$((i + 1))
            ;;
          '~'|'#')
            # Only a word-initial tilde/comment marker has shell semantics.
            [[ "$started" -eq 1 ]] || return 1
            word+="$c"; pattern+="$c"
            ;;
          *)
            case "$c" in '*'|'?'|'[') glob=1 ;; esac
            word+="$c"; pattern+="$c"; started=1
            ;;
        esac
        ;;
    esac
  done
  [[ "$state" == plain ]] || return 1
  if [[ "$started" -eq 1 ]]; then
    if [[ "$glob" -eq 1 ]] && compgen -G "$pattern" >/dev/null; then return 1; fi
    SEC_ARGV+=("$word")
  fi
  [[ ${#SEC_ARGV[@]} -gt 0 && -n "${SEC_ARGV[0]:-}" ]]
}

# Match a single argv option, including aliases and attached values. On success
# SEC_OPT_ATTACHED/SEC_OPT_VALUE describe whether the value was in this word.
# A separate value is consumed by the caller, never by splitting an argv word.
sec_arg_option() {
  local arg="$1" long="$2" short="${3:-}"
  SEC_OPT_ATTACHED=0
  SEC_OPT_VALUE=""
  if [[ "$arg" == "$long" || ( -n "$short" && "$arg" == "$short" ) ]]; then
    return 0
  elif [[ "$arg" == "$long="* ]]; then
    SEC_OPT_ATTACHED=1; SEC_OPT_VALUE="${arg#*=}"; return 0
  elif [[ -n "$short" && "$arg" == "$short"* ]]; then
    SEC_OPT_ATTACHED=1; SEC_OPT_VALUE="${arg#"$short"}"
    return 0
  fi
  return 1
}

# All deny checks receive argv, never a reconstructed command string.
sec_cmd_is_destructive() {
  case "${1:-}" in
    rm|dd|mkfs|mkfs.*) return 0 ;;
    git) case "${2:-}" in push|reset|clean) return 0 ;; esac ;;
    chmod) [[ "${2:-}" == 777 ]] && return 0 ;;
  esac
  return 1
}

sec_cmd_is_network_or_escape() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      curl|wget|nc|ncat|fetch|eval|/dev/tcp*) return 0 ;;
    esac
  done
  while [[ $# -gt 1 ]]; do
    case "$1" in
      bash|sh) [[ "$2" == -c* ]] && return 0 ;;
      python|python3|perl|ruby|node) [[ "$2" == -e* ]] && return 0 ;;
    esac
    shift
  done
  return 1
}

sec_cmd_is_package_install() {
  while [[ $# -gt 1 ]]; do
    case "$1" in
      npm|yarn|pnpm|bun) case "$2" in install|add|i) return 0 ;; esac ;;
    esac
    shift
  done
  return 1
}

# Conservative lexical config check, not a JS evaluator or execution sandbox.
# Never accept URLs found in comments or other parts of a baseURL expression.
# Unsupported lexical syntax fails closed; Python is already a hook dependency.
sec_config_base_urls() {
  python3 - "$1" <<'PY_CONFIG'
import pathlib
import re
import sys


def tokens(source):
    result = []
    i = 0
    while i < len(source):
        c = source[i]
        if c.isspace():
            i += 1
        elif source.startswith('//', i):
            end = re.search(r'[\n\r\u2028\u2029]', source[i + 2:])
            i = len(source) if end is None else i + 2 + end.end()
        elif source.startswith('/*', i):
            end = source.find('*/', i + 2)
            if end < 0:
                raise ValueError('unterminated comment')
            i = end + 2
        elif c in "\"'":
            quote = c
            start = i = i + 1
            escaped = False
            while i < len(source) and source[i] != quote:
                if source[i] in '\r\n':
                    raise ValueError('multiline quoted string')
                if source[i] == '\\':
                    escaped = True
                    i += 1
                i += 1
            if i >= len(source):
                raise ValueError('unterminated string')
            # Escaped keys could spell baseURL. Do not silently skip them.
            if escaped:
                raise ValueError('escaped strings require manual config review')
            result.append(('string', source[start:i]))
            i += 1
        elif c in '`\\/':
            raise ValueError('templates/escaped identifiers are not statically supported')
        elif c.isalpha() or c in '_$':
            start = i
            while i < len(source) and (source[i].isalnum() or source[i] in '_$'):
                i += 1
            result.append(('identifier', source[start:i]))
        else:
            result.append(('punctuation', c))
            i += 1
    return result


def base_urls(source):
    ts = tokens(source)
    urls = []
    for i, (kind, value) in enumerate(ts):
        if kind not in ('identifier', 'string') or value != 'baseURL':
            continue
        # Includes quoted property names. Reject shorthand/computed/accessor
        # forms instead of mistaking absence of a colon for absence of baseURL.
        if i + 3 >= len(ts) or ts[i + 1] != ('punctuation', ':'):
            raise ValueError('baseURL must be a literal property')
        literal_kind, literal = ts[i + 2]
        if literal_kind != 'string' or ts[i + 3] not in (
            ('punctuation', ','), ('punctuation', '}')
        ):
            raise ValueError('baseURL value is not a standalone string literal')
        if not re.match(r'^https?://', literal, re.I) or any(c.isspace() for c in literal):
            raise ValueError('baseURL must be an HTTP(S) URL literal')
        if '\x00' in literal:
            raise ValueError('NUL in baseURL')
        urls.append(literal)
    return urls


if __name__ == '__main__':
    try:
        urls = base_urls(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
        # Emit only after the entire file has passed, so a late error cannot
        # masquerade as successful partial validation in the shell caller.
        for url in urls:
            print(url)
    except (OSError, UnicodeError, ValueError) as exc:
        print(f'config baseURL unresolved: {exc}', file=sys.stderr)
        sys.exit(1)
PY_CONFIG
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

  if ! rm -f -- "$claim" 2>/dev/null || [[ -e "$claim" || -L "$claim" ]]; then
    return 1
  fi
  return 0
}
