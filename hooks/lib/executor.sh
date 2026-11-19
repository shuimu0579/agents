#!/usr/bin/env bash
# executor.sh — execution-only command allowlist for fleet executor roles (ADR 0006).
#
# Sourced by hooks/restrict-bash-by-agent.sh after security.sh. The caller has
# already tokenized the command into SEC_ARGV and applied the global deny rules
# (destructive, network/escape, package install); this library only decides whether
# that argv is inside the executor allowlist. It NEVER executes anything.
#
# Deliberately a separate library: the execution-only policy is additive to the
# legacy allowlist and must not widen hooks/lib/security.sh, which the rest of the
# fleet also consumes.
#
# Bash 3.2 (macOS) compatible. No `set -e`.
#
# exec_cmd_allowed <fleet_root> <argv...>  -> 0 allow, non-zero deny.
# Errors are reported by the caller (rule:allowlist); this library only returns status.

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

# exec_has_parent_segment <path> -> 0 if any path segment is exactly "..".
exec_has_parent_segment() {
  local rest="${1:-}" part
  while [[ -n "$rest" ]]; do
    if [[ "$rest" == */* ]]; then
      part="${rest%%/*}"; rest="${rest#*/}"
    else
      part="$rest"; rest=""
    fi
    [[ "$part" == ".." ]] && return 0
  done
  return 1
}

# exec_is_relative_path <path> -> 0 only for a non-empty relative path with no
# ".." segment and no leading dash (an option, not a positional).
exec_is_relative_path() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  [[ "$p" == /* ]] && return 1
  [[ "$p" == -* ]] && return 1
  exec_has_parent_segment "$p" && return 1
  return 0
}

# ---------------------------------------------------------------------------
# Read family
# ---------------------------------------------------------------------------

exec_is_read_cmd() {
  case "${1:-}" in
    ls|cat|head|tail|wc|grep|rg|stat|file|pwd|which) return 0 ;;
    # `command -v` is a lookup, never an execution.
    command) [[ "${2:-}" == "-v" ]] && return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Git (read-only)
# ---------------------------------------------------------------------------

# Options that change git's configuration, execution path, repository root,
# output destination, or diff helper. Any occurrence anywhere in argv denies.
#   -c / --config-env      inject config (aliases, core.pager, diff drivers)
#   --exec-path            change where git finds its subcommands
#   --git-dir / --work-tree / -C   retarget the repository
#   --paginate             spawn a pager
#   --output / --ext-diff / --textconv / --no-index  write output or run helpers
exec_git_option_denied() {
  local arg="${1:-}"
  case "$arg" in
    -c|-c*|-C|-C*) return 0 ;;
    --config-env|--config-env=*) return 0 ;;
    --exec-path|--exec-path=*) return 0 ;;
    --git-dir|--git-dir=*) return 0 ;;
    --work-tree|--work-tree=*) return 0 ;;
    --paginate) return 0 ;;
    --output|--output=*) return 0 ;;
    --ext-diff|--textconv|--no-index) return 0 ;;
  esac
  return 1
}

exec_is_git_readonly() {
  local sub="${2:-}" arg
  case "$sub" in
    status|diff|log|show|rev-parse) ;;
    *) return 1 ;;
  esac
  shift 2
  for arg in "$@"; do
    exec_git_option_denied "$arg" && return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Test runners
# ---------------------------------------------------------------------------

exec_reject_go_options() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -toolexec|-toolexec=*|-exec|-exec=*|-overlay|-overlay=*) return 1 ;;
    esac
  done
  return 0
}

exec_reject_make_options() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -f|-f*|--file|--file=*) return 1 ;;
      -C|-C*|--directory|--directory=*) return 1 ;;
      --eval|--eval=*|-I|-I*|--include-dir|--include-dir=*) return 1 ;;
    esac
  done
  return 0
}

exec_is_make_target() {
  case "${1:-}" in
    test|tests|check|lint|build) return 0 ;;
  esac
  return 1
}

exec_reject_nonoption() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Positional arguments of a test runner name files or packages that the runner
# will execute or import. ADR 0006: only relative paths with no ".." segment;
# absolute paths are refused. Option tokens are skipped; an option value that is
# itself an absolute path is therefore also refused, which is intentional (for
# example `go test -coverprofile /tmp/out` writes outside the repo).
exec_check_relative_positionals() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -*) continue ;;
    esac
    exec_is_relative_path "$arg" || return 1
  done
  return 0
}

exec_is_test_runner() {
  local name="${1:-}"
  case "$name" in
    pytest)
      shift
      exec_check_relative_positionals "$@"
      ;;
    go)
      [[ "${2:-}" == "test" ]] || return 1
      shift 2
      exec_reject_go_options "$@" || return 1
      exec_check_relative_positionals "$@"
      ;;
    cargo)
      [[ "${2:-}" == "test" ]] || return 1
      shift 2
      exec_check_relative_positionals "$@"
      ;;
    make)
      exec_is_make_target "${2:-}" || return 1
      shift 2
      exec_reject_make_options "$@" || return 1
      exec_reject_nonoption "$@"
      ;;
    npm|pnpm|yarn|bun)
      case "${2:-}" in
        test) [[ $# -eq 2 ]] || return 1 ;;
        run)
          [[ $# -eq 3 ]] || return 1
          case "${3:-}" in
            test|tests|lint|typecheck|check|build) ;;
            *) return 1 ;;
          esac
          ;;
        *) return 1 ;;
      esac
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Python modules
# ---------------------------------------------------------------------------

# python3 -m unittest [tokens...]
# Allowed tokens: -v, discover, -s|-p|-t followed by one non-option value, or a
# test name (dotted identifiers). -s/-t name directories and must be relative.
exec_unittest_args() {
  local arg val
  while [[ $# -gt 0 ]]; do
    arg="$1"; shift
    case "$arg" in
      -v|discover) ;;
      -s|-p|-t)
        [[ $# -gt 0 ]] || return 1
        val="$1"; shift
        [[ -n "$val" && "$val" != -* ]] || return 1
        case "$arg" in
          -s|-t) exec_is_relative_path "$val" || return 1 ;;
        esac
        ;;
      *)
        [[ "$arg" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]] || return 1
        ;;
    esac
  done
  return 0
}

# json.tool reads one optional file and writes formatted output to stdout.
exec_single_optional_file() {
  local arg count=0
  for arg in "$@"; do
    case "$arg" in
      -*) return 1 ;;
    esac
    count=$((count + 1))
    [[ "$count" -le 1 ]] || return 1
  done
  return 0
}

exec_py_module_allowed() {
  [[ $# -ge 3 ]] || return 1
  [[ "${2:-}" == "-m" ]] || return 1
  local module="${3:-}"
  shift 3
  case "$module" in
    pytest) exec_check_relative_positionals "$@" ;;
    unittest) exec_unittest_args "$@" ;;
    json.tool) exec_single_optional_file "$@" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Fleet test scripts: bash|sh <path under ${FLEET_ROOT}/tests, .sh, regular file>
# ---------------------------------------------------------------------------

# Resolve symlinks and compare against the hook's own fleet root. `..` is refused
# before canonicalization so the lexical answer and the physical answer agree.
# python3 is already a hook dependency; when it is missing the family fails closed.
exec_is_script_path() {
  local fleet_root="${1:-}" path="${2:-}"
  [[ -n "$fleet_root" && -n "$path" ]] || return 1
  [[ "$path" != -* ]] || return 1
  exec_has_parent_segment "$path" && return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$fleet_root" "$path" <<'PY_EXEC_PATH'
import os
import sys

root = os.path.realpath(sys.argv[1])
real = os.path.realpath(sys.argv[2])
if not os.path.isfile(real):
    sys.exit(1)
if sys.platform == "darwin":
    root = root.casefold()
    real = real.casefold()
tests = os.path.join(root, "tests") + os.sep
hooks = os.path.join(root, "hooks") + os.sep
scripts = os.path.join(root, "scripts") + os.sep
ok = (
    real.startswith(tests)
    and not real.startswith(hooks)
    and not real.startswith(scripts)
    and real.endswith(".sh")
)
sys.exit(0 if ok else 1)
PY_EXEC_PATH
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

# exec_cmd_allowed <fleet_root> <argv...>
# Unknown commands, empty argv, and anything the library cannot classify deny.
exec_cmd_allowed() {
  local fleet_root="${1:-}"
  shift || return 1
  [[ $# -ge 1 && -n "${1:-}" ]] || return 1
  case "$1" in
    ls|cat|head|tail|wc|grep|rg|stat|file|pwd|which|command)
      exec_is_read_cmd "$@"
      ;;
    git)
      exec_is_git_readonly "$@"
      ;;
    pytest|go|cargo|make|npm|pnpm|yarn|bun)
      exec_is_test_runner "$@"
      ;;
    python3)
      exec_py_module_allowed "$@"
      ;;
    bash|sh)
      exec_is_script_path "$fleet_root" "${2:-}"
      ;;
    *)
      return 1
      ;;
  esac
}
