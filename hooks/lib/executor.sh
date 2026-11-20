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

# Python helpers live beside this file (ADR 0008 / audit B7): a script file avoids
# Bash 3.2 here-documents, which need writable temporary storage.
EXEC_PY_DIR="${EXEC_PY_DIR:-$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/py}"
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
# Git (orchestrator: read + write, ADR 0007)
# ---------------------------------------------------------------------------

# Subcommands that run an external program or rewrite git's own configuration:
# `config` can set core.hooksPath/core.pager; `bisect run`, `difftool`, `mergetool`
# and the filter family execute arbitrary commands.
exec_git_write_sub_denied() {
  case "${1:-}" in
    config|help|daemon|credential|difftool|mergetool|filter-branch|filter-repo|bisect|instaweb|pager|web--browse|send-email|request-pull|shell|http-backend) return 0 ;;
  esac
  return 1
}

# Options that turn a write subcommand into arbitrary command execution, plus the
# push options that rewrite or delete remote history. `--force-with-lease` is
# deliberately NOT matched: it is the guarded form.
exec_git_write_arg_denied() {
  local sub="${1:-}" arg="${2:-}"
  case "$arg" in
    --exec|--exec=*|--upload-pack|--upload-pack=*|--receive-pack|--receive-pack=*) return 0 ;;
    --tree-filter|--tree-filter=*|--index-filter|--index-filter=*) return 0 ;;
  esac
  if [[ "$sub" == "push" ]]; then
    case "$arg" in
      --force|-f|-f*|--mirror|--delete|--delete=*|+*) return 0 ;;
    esac
  fi
  return 1
}

exec_is_git_write() {
  local sub="${2:-}" arg
  case "$sub" in
    status|diff|log|show|rev-parse) ;;
    add|commit|branch|checkout|switch|merge|rebase|stash|pull|fetch|push|tag|restore|reset|clean|rm|mv|cherry-pick|revert|remote|reflog|gc|prune|init|clone) ;;
    *) return 1 ;;
  esac
  exec_git_write_sub_denied "$sub" && return 1
  shift 2
  for arg in "$@"; do
    exec_git_option_denied "$arg" && return 1
    exec_git_write_arg_denied "$sub" "$arg" && return 1
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
  [[ -n "${EXEC_PY_DIR:-}" && -f "$EXEC_PY_DIR/exec_script_path.py" ]] || return 1
  python3 -I "$EXEC_PY_DIR/exec_script_path.py" "$fleet_root" "$path"
}
# ---------------------------------------------------------------------------
# External CLI dispatcher: bash <fleet>/tools/agent-cli.sh <role> <prompt...>
# ---------------------------------------------------------------------------

# ADR 0008. The external CLIs (agy, codex, grok) are agentic: they can write files
# and run commands. Admitting them by name would be an arbitrary-execution grant,
# so the gate admits only the pinned wrapper, and the wrapper owns model and
# safety flags.
#
# Single source of truth for caller-to-route policy (audit #13): consumed by both
# the PreToolUse Bash gate and tools/agent-cli.sh.
exec_agent_cli_route() {
  case "${1:-}" in
    mark)     printf 'agy|gemini-4-hydrogen-xhigh\n' ;;
    posca)    printf 'agy|gemini-4-argon-high\n' ;;
    vorenus)  printf 'agy|gemini-pro-orchestrator-neon\n' ;;
    octavion) printf 'codex|gpt-6.2-sol\n' ;;
    atia)     printf 'grok|grok-4.7\n' ;;
    *)        return 1 ;;
  esac
}

exec_agent_cli_roles() {
  printf 'mark octavion posca atia vorenus'
}

exec_agent_cli_role_allowed() {
  exec_agent_cli_route "${1:-}" >/dev/null
}

# Validate the prompt payload (after argv or stdin assembly) so a prompt cannot
# select CLI options, headless slash commands, or backend subcommands (audit #8, #9).
# ADR 0008 / audit B8: every backend receives the prompt through an explicit data
# channel (agy --print=, codex stdin `-`, grok -p value), so a prompt can no longer
# be read as a subcommand. An earlier first-word denylist rejected ordinary review
# prompts such as "Review the patch" and was removed.
exec_agent_cli_prompt_valid() {
  local prompt="${1:-}" trimmed
  [[ -n "${prompt//[[:space:]]/}" ]] || return 1
  trimmed="${prompt#"${prompt%%[![:space:]]*}"}"
  [[ -n "$trimmed" ]] || return 1
  case "$trimmed" in
    -*|/*) return 1 ;;
  esac
  return 0
}

exec_is_agent_cli() {
  local fleet_root="${1:-}" path="${2:-}" role="${3:-}" caller="${4:-${agent:-}}"
  [[ $# -ge 5 ]] || return 1
  [[ -n "$fleet_root" && -n "$path" && -n "$role" && -n "$caller" ]] || return 1
  # Audit B4/B13: classify the exact wrapper path first, and require an absolute
  # spelling. A relative path resolves against the hook process's working
  # directory, not the event's execution directory, so it is refused outright.
  case "$path" in
    /*/tools/agent-cli.sh) ;;
    *) return 1 ;;
  esac
  exec_has_parent_segment "$path" && return 1
  [[ "$role" == "$caller" ]] || return 1
  exec_agent_cli_role_allowed "$role" || return 1
  shift 4
  local arg
  for arg in "$@"; do
    case "$arg" in
      -*) return 1 ;;
    esac
  done
  exec_agent_cli_prompt_valid "$*" || return 1
  [[ -n "${EXEC_PY_DIR:-}" && -f "$EXEC_PY_DIR/exec_cli_path.py" ]] || return 1
  python3 -I "$EXEC_PY_DIR/exec_cli_path.py" "$fleet_root" "$path"
}
# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

# exec_orchestrator_cmd_allowed <fleet_root> <argv...>
# ADR 0007: the orchestrator keeps the executor allowlist and additionally holds
# standing git write authority (including push/reset/clean). Non-git commands are
# unchanged, so the executor boundary is not widened for any other role.
exec_orchestrator_cmd_allowed() {
  local fleet_root="${1:-}"
  shift || return 1
  [[ $# -ge 1 && -n "${1:-}" ]] || return 1
  case "$1" in
    git) exec_is_git_write "$@" ;;
    *) exec_cmd_allowed "$fleet_root" "$@" ;;
  esac
}

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
    bash)
      # The pinned external-CLI wrapper (ADR 0008) is the only executable this
      # family admits outside tests/, and only via bash: the role is bound to the
      # attributed caller, and the wrapper refuses options/subcommands.
      if [[ $# -ge 4 ]] && exec_is_agent_cli "$fleet_root" "${2:-}" "${3:-}" "${agent:-}" "${@:4}"; then
        return 0
      fi
      exec_is_script_path "$fleet_root" "${2:-}"
      ;;
    sh)
      exec_is_script_path "$fleet_root" "${2:-}"
      ;;
    *)
      return 1
      ;;
  esac
}
