---
status: accepted
date: 2026-11-20
supersedes: 0006 (review roles mark, octavion, atia; executor wrapper grants for posca, vorenus)
---

# Default external-CLI routes for review and executor roles

## Context and Problem Statement

The user assigned each role a default external model (2026-11-20):

| Role | CLI | Model |
|---|---|---|
| mark | `agy` | `gemini-4-hydrogen-xhigh` |
| octavion | `codex` | `gpt-6.2-sol`, effort `xhigh` |
| posca | `agy` | `gemini-4-argon-high` |
| atia | `grok` | `grok-4.7` |
| vorenus | `agy` | `gemini-pro-orchestrator-neon` |

`anthory` and `pullo` stay on the host (Claude Code CLI) session model.

Under ADR 0006, `mark`, `octavion` and `atia` declared no `Bash`, and the executor
allowlist admitted no external CLI. Claude Code's `model:` field cannot carry these
IDs either — it accepts only host model names, and the fleet pins `inherit`. So the
mapping had nowhere to run until the gate admitted a route.

## Decision Drivers

* The CLI must be usable by the role itself, not only by the main session.
* `agy`, `codex` and `grok` are agentic: each can write files and execute commands.
  A raw allowlist entry for the binary would be an arbitrary-execution grant and
  would defeat the Write/Edit gate.
* The review roles must stay non-writers (`review_only` bans `Write`/`Edit` and the
  tests assert it).
* The `model` contract column is a fleet invariant: `inherit` for all seven.

## Considered Options

* **Allow `agy`/`codex`/`grok` directly in the allowlist.** Rejected: it grants an
  agentic CLI with no fixed flags; `codex exec --dangerously-bypass-...` or
  `grok --always-approve` would pass the gate.
* **Route everything through the main session.** Rejected by the user's choice:
  the role itself should invoke its default model.
* **Pinned wrapper script as the single admitted shape.** Chosen.

## Decision Outcome

* New file `tools/agent-cli.sh`, invoked via `bash` with its **absolute** fleet
  path: `bash /Users/suimu/.claude/agents/tools/agent-cli.sh <role> "<prompt>"`.
  The relative form is refused (audit B4): a relative path resolves against the
  hook process's working directory, not the event's execution directory, so the
  authorization and the execution could name different files. Any symlink in the
  path is refused, and the final file must be the same inode as
  `<fleet>/tools/agent-cli.sh`.
  * `tools/` is protected by `hooks/restrict-mutator-write.sh` (`rule:self-protect`),
    next to `hooks/`, `tests/` and `scripts/`, so no attributed agent can modify or
    replace the wrapper.
  * `hooks/lib/executor.sh` is the single source of truth for the role → CLI → model
    table (`exec_agent_cli_route`) and prompt validation (`exec_agent_cli_prompt_valid`).
  * Python helpers live as files under `hooks/lib/py/` rather than here-documents.
    Bash 3.2 backs a here-document with a temporary file, so a read-only temp
    directory made valid routes fail closed (audit B7); a script file needs no temp.
    The helpers run with `python3 -I` so an inherited environment cannot change them.
  * The stdin prompt reader enforces one monotonic 2-second deadline for the whole
    payload, not per read, so an intermittent stream cannot extend it (audit B5);
    blank payloads are rejected in the reader without a Bash-side whitespace pass.
  * The `grok` route also pins the built-in tool set
    (`--tools read_file,grep,list_dir`), not just the sandbox profile, so project
    settings cannot widen the effective review permissions (audit B11).
  * The wrapper resolves `agy`, `codex` and `grok` once to a verified physical path,
    refuses any binary living under agent-writable trees (`${FLEET_ROOT}`, `/tmp`,
    `/var/tmp`), world-writable directories/files, or untrusted owners, and requires
    the binary's SHA-256 to match `tools/cli-sha256` immediately before `exec`.
    `tools/` is agent-immutable (see above), so the pin cannot be rewritten alongside
    the binary. A CLI upgrade therefore fails closed until the pin is refreshed:

    ```bash
    bash tools/pin-clis.sh           # re-pin after a deliberate upgrade
    bash tools/pin-clis.sh --check   # exit 1 if stale; writes nothing
    ```

    The script is main-session-only: the Bash gate admits agents to
    `tools/agent-cli.sh` and fleet `tests/*.sh`, never to `tools/pin-clis.sh`, so
    a compromised agent cannot bless a binary it replaced. A hash mismatch fails
    closed and the error names this command; auto-trust on first use is
    deliberately not offered.

    `FLEET_CLI_PIN_FILE` overrides the pin path for the test harness only; an
    attributed agent cannot set it, because the gate admits only `bash <wrapper> …`
    and an environment assignment would change `argv[0]`.
  * Each backend uses an explicit non-interactive prompt channel and pinned flags:
    * `agy --sandbox --disable-slash-commands --model <model> "--print=<prompt>"`
    * `codex exec --ignore-user-config -s read-only -m <model> -c model_reasoning_effort="xhigh" -`
      (prompt delivered on stdin)
    * `grok --sandbox read-only --model <model> -p "<prompt>"`
  * Option-looking (`-*`), slash-command (`/*`), and reserved subcommand prompts are
    refused across both argv and bounded stdin, without echoing rejected prompt text.
* New contract flag `review_cli` for `mark`, `octavion`, `atia`: `Bash` is declared,
  but the gate admits only `bash` (never `sh`), requires the exact fleet wrapper path
  (rejecting symlinks, `..`, case-folded paths, or outside-fleet copies), binds the
  `<role>` argument to the attributed `agent_type`, and denies every other command
  with `rule:allowlist`. They remain non-writers at the Claude tool layer.
* Write protection for `tools/` is decided by filesystem identity (`st_dev`/`st_ino`
  of the target's nearest existing ancestor chain), not by canonicalized string
  prefixes: on APFS the same file has a second canonical spelling
  (`/System/Volumes/Data/...`) that a prefix test misses.
* The gate caps a command at 16384 bytes before tokenizing (`rule:command-too-long`).
  Bash 3.2 tokenizes character by character: 8 KiB costs ~2.7s and 32 KiB ~37s
  against a 5s hook timeout.
* The prompt validator refuses only option-looking (`-*`), slash-command (`/*`) and
  blank prompts. There is no first-word subcommand denylist: every backend receives
  the prompt through an explicit data channel, and the denylist rejected legitimate
  prompts such as "Review the patch".
* Executor roles with a mapping (`posca`, `vorenus`) reach the same `exec_is_agent_cli`
  rule for their own bound `<role>`; unmapped roles (`anthory`, `pullo`) and cross-role
  calls are denied with `rule:allowlist`.
* `tests/guardrails.sh` accepts `review_cli` and requires `Bash` while banning
  `Write`/`Edit`.

## Consequences and Residual Risks

* **Authorization gate, not a read-only sandbox (ADR 0003).** The wrapper pins vendor
  flags, but none of the three CLIs provides airtight read-only containment:
  * **`agy --sandbox` is read-write workspace isolation, not read-only.** It enables
    terminal restrictions in print mode (`--disable-slash-commands` prevents headless
    slash-command/skill expansion), but `agy` can still write within the workspace and
    host/session permissions can authorize actions outside it. It must not be treated
    as a "cannot write" guarantee.
  * **`codex exec -s read-only` governs model-generated shell commands only.** Passing
    `--ignore-user-config` prevents `$CODEX_HOME/config.toml` from loading ambient
    user MCP servers (which otherwise run outside the shell sandbox), while keeping
    `CODEX_HOME` authentication. Project-scoped config or non-shell capabilities
    remain governed by Codex rather than this hook.
  * **`grok --sandbox read-only` still allows temporary and state writes.** Grok's
    read-only profile permits writes to temp and state directories (such as `~/.grok`
    and system temp paths), and child-process network access is unrestricted on macOS.
* **Tokenizer constraints on the prompt argument.** Because the PreToolUse Bash gate
  tokenizes commands with `sec_cmd_tokenize` (which rejects shell metacharacters,
  newlines, `$`, backticks, and word-initial `~`), agents must invoke the wrapper via
  its literal absolute path `/Users/suimu/.claude/agents/tools/agent-cli.sh` and pass
  a single-line plain prompt argument without shell metacharacters.
* `codex -m gpt-6.2-sol` and `grok` require credentials the host must supply; a
  missing login surfaces as the CLI's own error, not a gate decision.
* The wrapper bounds stdin reads (one 2s deadline, 64 KiB cap) when called without
  argv, but does not impose a wall-clock timeout on the external model turn itself.
* **Prompt exposure (audit B12, low).** `codex` receives the prompt on stdin. `agy`
  and `grok` receive it as a process argument (`--print=`, `-p`), and the wrapper
  itself is invoked with the prompt in its own argv, so the text is visible to
  same-user process listings for those routes. A private channel exists only where
  the vendor offers one; treating this as closed would require changing the vendor
  CLI surface.`

* ADR 0006's role table is historical for `mark`, `octavion` and `atia`; its executor
  boundary and accepted residuals remain in force.

## Links

* Partially supersedes: [0006](0006-7-role-bash-authorization.md)
* Still in force: [0003](0003-enforcement-boundary-and-accepted-residual-risk.md), [0007](0007-orchestrator-standing-git-authority.md)
* Implementation: `tools/agent-cli.sh`, `hooks/lib/executor.sh`, `hooks/restrict-bash-by-agent.sh`, `hooks/restrict-mutator-write.sh`, `tests/guardrails.sh`
