---
status: accepted
date: 2026-11-20
supersedes: 0008 (sandbox levels for codex and grok, and the grok built-in tool pin)
---

# Switch external CLI routes in `tools/agent-cli.sh` to workspace-write sandboxes

## Context and Problem Statement

ADR 0008 introduced `tools/agent-cli.sh` as the single pinned dispatcher for
roles with a default external CLI (`agy`, `codex`, `grok`). In that initial
configuration, `codex` was pinned to `-s read-only` and `grok` was pinned to
`--sandbox read-only --tools "read_file,grep,list_dir"`, while `agy` used
`--sandbox` (which is already workspace-writable isolation).

The user directed on 2026-11-20 that the `codex` and `grok` routes also be
made read-write within the workspace ("可读可写"), while keeping `agy`'s
existing invocation unchanged.

How should `tools/agent-cli.sh` configure the sandbox and built-in tool flags
for `codex` and `grok`?

## Decision Drivers

* Explicit user requirement that `codex` and `grok` external CLI routes be
  workspace-writable rather than read-only.
* As already documented in ADR 0008's Consequences, vendor `read-only` flags
  were never airtight read-only containment (`agy --sandbox` was already
  read-write workspace isolation, `codex -s read-only` only governed
  model-generated shell commands, and `grok --sandbox read-only` still allowed
  temporary/state writes and unrestricted child-process network access).
* The wrapper must continue to pin the exact CLI binary hash, model, and
  explicit non-interactive prompt channels, without option passthrough.
* `grok`'s valid sandbox profiles are `workspace`, `read-only`, and `strict`
  (not `workspace-write`), and its built-in file-mutation tool IDs are `write`
  and `search_replace`.

## Considered Options

* **Keep `codex` and `grok` on `read-only` flags.** Rejected: directly
  contradicts the user's requirement for workspace-writable routes.
* **Remove `--sandbox` / `-s` and `--tools` restrictions entirely.** Rejected:
  dropping sandbox profiles or tool pinning would allow project or user config
  to widen execution authority beyond workspace-scoped file operations.
* **Pin `codex` to `-s workspace-write` and `grok` to `--sandbox workspace`
  with `--tools "read_file,grep,list_dir,write,search_replace"`, leaving `agy`
  unchanged.** Chosen.

## Decision Outcome

* In `tools/agent-cli.sh`:
  * `codex` runs with:
    `codex exec --ignore-user-config -s workspace-write -m <model> -c model_reasoning_effort="xhigh" -`
    (prompt delivered on stdin).
  * `grok` runs with:
    `grok --sandbox workspace --tools "read_file,grep,list_dir,write,search_replace" --model <model> -p "<prompt>"`.
  * `agy` remains unchanged:
    `agy --sandbox --disable-slash-commands --model <model> "--print=<prompt>"`.
* The other ADR 0008 controls continue to apply at the Claude tool layer:
  physical binary resolution outside agent-writable trees, pre-exec SHA-256
  verification against `tools/cli-sha256`, role-to-caller binding in
  `hooks/restrict-bash-by-agent.sh`, and prompt validation against options,
  slash commands, and blank payloads. They do **not** extend inside the external
  CLI turn: the vendor sandbox is the only boundary there, and the Claude
  PreToolUse hooks — including `tools/` self-protection by filesystem identity —
  do not run. When the invoking cwd is the fleet root, a `workspace-write` /
  `workspace` turn can therefore rewrite `tools/agent-cli.sh`,
  `tools/cli-sha256`, `hooks/`, `tests/`, root `*.md`, and `.git/hooks`; the pin
  can be rewritten alongside what it protects. This is an accepted residual, not
  a guarantee.

## Consequences and Residual Risks

* **Review roles gain workspace write capability through their external CLI
  route.** `mark` (`agy`), `octavion` (`codex`), and `atia` (`grok`) still
  carry `review_cli` in the fleet contract and remain barred from Claude Code's
  native `Write` and `Edit` tools, but dispatching through `tools/agent-cli.sh`
  now runs all three external backends in a workspace-writable sandbox.
* **Vendor sandbox boundaries remain best-effort (ADR 0003).** Neither
  `codex -s workspace-write`, `grok --sandbox workspace`, nor `agy --sandbox`
  intercepts every child-process side effect or network operation on macOS, and
  none of them enforces the Claude PreToolUse `Write`/`Edit` self-protection
  hook (`hooks/restrict-mutator-write.sh`) inside the external CLI turn.
* **`grok` child-process network policy changes on Linux.** The `read-only`
  profile blocks child-process network (seccomp); `workspace` allows it. The
  vendor documents network blocking as a no-op on macOS, so this host sees no
  change either way; in-process HTTP by built-in tools was never affected.
* **Binary hash pins are unchanged.** Because only wrapper arguments changed
  and the underlying CLI binaries did not, `tools/cli-sha256` does not need to
  be regenerated.

## Links

* Supersedes: [0008](0008-default-external-cli-routes.md) (sandbox levels for `codex` and `grok`, and the grok built-in tool pin; every other ADR 0008 control stays in force at the Claude tool layer)
* Still in force: [0003](0003-enforcement-boundary-and-accepted-residual-risk.md), [0006](0006-7-role-bash-authorization.md), [0007](0007-orchestrator-standing-git-authority.md)
* Implementation: `tools/agent-cli.sh`, `hooks/restrict-bash-by-agent.sh`, `tests/hooks.test.sh`
