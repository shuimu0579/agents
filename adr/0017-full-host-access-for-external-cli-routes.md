---
status: accepted
date: 2026-11-23
supersedes: 0010
---

# Full host access for external CLI routes

## Context and Problem Statement

ADR 0010 pinned the external CLI routes to workspace-write sandboxes: `agy` kept
`--sandbox`, `codex` used `-s workspace-write`, and `grok` used `--sandbox
workspace` with a fixed read/write tool set. That kept the agentic CLIs inside a
filesystem boundary, but it also limited what the designated model could do.

On 2026-11-23 the user asked to give all three CLIs the highest permissions. This
ADR records the resulting permission change and its accepted risk.

## Decision Drivers

* The user explicitly authorized full host access for `agy`, `codex` and `grok`.
* The user wants the designated CLI model to do the work first (ADR 0016); the
  sandbox was the remaining limit on that work.
* The wrapper still has to pin the CLI, model and exact flags; agents must not be
  able to pass extra options.

## Considered Options

* **Keep workspace-write sandboxes.** Rejected by the user's explicit request.
* **Auto-approve but keep the sandbox.** Rejected: it leaves the filesystem
  boundary the user asked to remove.
* **Remove sandbox and approval prompts.** Chosen.

## Decision Outcome

* `agy`: `--dangerously-skip-permissions --disable-slash-commands --model <model>
  --print=<prompt>`; the `--sandbox` flag is removed.
* `codex`: `exec --ignore-user-config --dangerously-bypass-approvals-and-sandbox
  -m <model> -c model_reasoning_effort="xhigh" -`; the `-s workspace-write` policy
  is removed.
* `grok`: `--always-approve --permission-mode bypassPermissions --model <model>
  -p <prompt>`; the `--sandbox workspace` profile and the `--tools` allowlist are
  removed.
* The wrapper still resolves each binary to a trusted physical path, verifies its
  SHA-256 against `tools/cli-sha256`, and pins the CLI, model and flags. Role
  binding (`role == caller`), cross-role denial, and the `bash`-only invocation
  shape are unchanged.
* This supersedes ADR 0010's sandbox policy. ADR 0008's optional-route wording is
  already superseded by ADR 0016; the route table itself is unchanged.

## Consequences

* Accepted risk (user-approved): each external turn can read and write anywhere
  the invoking user can, execute arbitrary commands, and use the network. It runs
  outside the Claude PreToolUse hooks (ADR 0003), so the fleet's Write/Edit
  self-protection and Bash allowlist do not apply inside that turn.
* Prompt injection in repository content is more dangerous now: the external model
  is no longer confined to a workspace sandbox. Only run tasks whose inputs are
  trusted, or keep the wrapper's prompt construction disciplined.
* Codex's own help text calls `--dangerously-bypass-approvals-and-sandbox`
  "EXTREMELY DANGEROUS" and intended for environments that are externally
  sandboxed. This host is not externally sandboxed; the control is the user's
  explicit approval plus the wrapper's fixed flags and binary pin.
* Every role's dispatched command and external response remain in the vendor's
  session logs for after-the-fact review.
* Tests assert the new argv for all three backends.

## Links

* Supersedes: [0010](0010-cli-routes-workspace-write.md)
* Related: [0016](0016-external-cli-first-for-all-roles.md),
  [0015](0015-anthory-default-orchestrator-neon-route.md),
  [0008](0008-default-external-cli-routes.md),
  [0003](0003-enforcement-boundary-and-accepted-residual-risk.md)
* Implementation: `tools/agent-cli.sh`, `tests/hooks.test.sh`, role definitions,
  `AGENTS.md`
