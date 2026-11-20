---
status: accepted
date: 2026-11-20
supersedes: 0012 (machine-state observation only; the retirement decision stands)
---

# Register the fleet's four gates as Grok hooks

## Context and Problem Statement

ADR 0012 recorded that, on this machine, Grok registered none of the fleet's gates:
`~/.grok/hooks/agent-gates.json` was absent and `[compat.claude] hooks = false` in
`~/.grok/config.toml` stops Grok from importing the Claude settings. The gates
therefore constrained only Claude Code dispatches. The user asked to close that gap.

Grok 1.0.89 loads personal hooks from `~/.grok/hooks/*.json` (matcher groups) and also
from `config.toml`; `[compat.claude] hooks = false` only stops it from importing
`~/.claude/settings.json`. Its hook contract matches the fleet's assumptions:

* a `PreToolUse` hook that exits 2 is an explicit deny;
* the event arrives as JSON on stdin with `toolInput` and `subagentType`, which
  `hooks/lib/*` already accepts alongside the Claude spellings;
* a matcher is a regex over the tool name, Claude-style `Bash` matches
  `run_terminal_cmd`, but `Write` aliases to `search_replace` only, so the native
  `write` must be named explicitly;
* a crash or timeout fails open unless the hook sets `failClosed`.

## Considered Options

* **Leave Grok unregistered.** Rejected: a Grok-dispatched agent would bypass every
  fleet gate, which is the failure mode `AGENTS.md` calls out.
* **Set `[compat.claude] hooks = true` and reuse the Claude settings.** Rejected: it
  would also import every unrelated Claude hook, and the Grok-specific matcher
  spellings would still be missing.
* **Write `~/.grok/hooks/agent-gates.json` with the four fleet gates and their
  Grok-specific matchers.** Chosen.

## Decision Outcome

Chosen option: **"Register the four gates natively in Grok."**

`~/.grok/hooks/agent-gates.json` registers:

* `PreToolUse` `Bash` (the Claude-style alias Grok matches to its shell tool) →
  `restrict-bash-by-agent.sh`, timeout 5;
* `PreToolUse` `Write|Edit|write` → `restrict-mutator-write.sh`, timeout 5;
* `PreToolUse` `Write|write` → `xixi/restrict-write.sh`, timeout 5;
* `PostToolUse` `Write|write` → `xixi/copy-on-write.sh`, timeout 15.

The three `PreToolUse` handlers set `failClosed: true`, so a timeout, crash or
unreadable reply denies the call. The `PostToolUse` handler does not set it: that event
cannot block, so a failure is only recorded.

The Claude settings remain registered and are skipped by Grok because
`[compat.claude] hooks = false`, so no gate runs twice.

### Consequences

* Good, because a subagent that Grok itself spawns is now subject to the same Bash,
  write and `_xixi` gates as a Claude Code subagent. Those events carry
  `subagentType`, which the gate scripts already read.
* Good, because the registration is a plain JSON file outside the repository, so it
  can be reviewed without touching the fleet tree.
* Bad, because the fleet's own `tools/agent-cli.sh atia` route runs Grok as a headless
  **main session** (`grok ... -p`). Those tool events carry no `subagentType`, so the
  fleet gates pass them through as main-session traffic; that turn remains bounded only
  by the vendor sandbox and the pinned `--tools` allowlist (ADR 0010). Only Grok's own
  spawned subagents are gated.
* Bad, because in an interactive session an untrusted workspace holds these user hooks
  back. Home directories and filesystem roots count as trusted, and a headless
  `grok -p` run counts the folder as trusted for the user's own hooks; this machine's
  fleet root is already recorded as trusted.
* Neutral, because the `PreToolUse` gates now fail closed on their own failures while
  the Claude-side gates still fail open; the two hosts differ until Claude Code
  supports `onFailure` (this machine runs 2.1.285, which does not).
* Bad, because a `PostToolUse` failure is only recorded. That event cannot block, so
  the difference is observational only.

## Verification and rollback

* **Verify:** `grok inspect --json` in the fleet root lists all four handlers with
  `source.type == "user"`, `source.path == "~/.grok/hooks"`, and no `disabled` flag. A
  snapshot of the 2026-11-20 run is kept at `~/.grok/agent-gates.inspect.json`
  (outside `hooks/`, so Grok does not load it).
* **Assert:** `bash tests/grok-hooks-registration.test.sh` checks the four scripts,
  matchers, timeouts and `failClosed`. It skips when the file is absent, so machines
  without Grok stay green.
* **Rollback:** delete `~/.grok/hooks/agent-gates.json` and re-run `grok inspect
  --json`; the four entries disappear. No repository change is needed.

## Links

* Supersedes: [0012](0012-retire-xixi-as-a-fleet-agent.md) (machine-state observation
  only; `_xixi` remains retired)
* Registration: `~/.grok/hooks/agent-gates.json` (not version-controlled)
* Gates: `hooks/restrict-bash-by-agent.sh`, `hooks/restrict-mutator-write.sh`,
  `hooks/xixi/restrict-write.sh`, `hooks/xixi/copy-on-write.sh`
* Verified with `grok inspect --json`: all four appear with source
  `~/.grok/hooks`, no `disabled` flag; the Claude-sourced duplicates stay disabled.
