---
status: accepted
date: 2026-11-23
supersedes: 0008 (optional-consultation wording and the pullo-unmapped clause)
---

# External CLI first for every fleet role

## Context and Problem Statement

ADR 0008 assigned each role a default external model through
`tools/agent-cli.sh`, but left its use optional: a role could read files, form its
own judgment and issue a verdict entirely on the host session model. The user wants
the designated CLI model to do the work first, for all seven roles (2026-11-23).

The platform cannot make the external model the subagent's runtime: Claude Code's
`model:` accepts only host model IDs, and this host is a DeepSeek
Anthropic-compatible endpoint. The closest achievable behaviour is to make the
role's first action a one-shot external CLI call, with the external CLI doing the
main work in its own sandbox.

## Decision Drivers

* The user wants the designated CLI model, not the host model, to do the work first.
* The external CLI has its own tools and sandbox and inherits the working
  directory, so it can read files and act without the host pre-reading them.
* `pullo` must have a designated route too; leaving it unmapped contradicts
  "all seven".
* The fleet's hooks still gate the host-side agent (ADR 0006 / 0007); the external
  CLI remains outside those hooks (ADR 0010, accepted residual).

## Considered Options

* **Keep "consult before verdict" only.** Rejected: the host model still forms the
  first judgment and may pre-read files.
* **Host model as a thin relay, external CLI first.** Chosen for the current
  subagent architecture.
* **Run every role as a standalone external CLI process.** Rejected for this ADR:
  it bypasses the Claude Code hooks and the subagent tool loop; a separate launcher
  design would need its own ADR.

## Decision Outcome

* All seven roles are mapped: `mark` → agy `gemini-4-hydrogen-xhigh`, `octavion` →
  codex `gpt-6.2-sol` (xhigh), `posca` → agy `gemini-4-argon-high`, `atia` → grok
  `grok-4.7`, `vorenus` → agy `gemini-pro-orchestrator-neon`, `anthory` → agy
  `gemini-pro-orchestrator-neon`, `pullo` → agy `gemini-pro-orchestrator-neon`.
* Each role's **first step** on a task is to call its bound
  `bash tools/agent-cli.sh <role> "<task + known context>"` route, before reading
  repository files or forming its own conclusion. The external CLI inherits the cwd
  and does the main analysis/work with its own tools and sandbox.
* The host-model agent then relays the external output as the report body, adding
  only the report template and clearly-labelled minimal supplements; it must not
  substitute its own independent judgment.
* Fallback to the host model is allowed only when the task explicitly does not need
  the external model or the CLI is missing/unauthenticated; the delivery must state
  the fallback.
* `model: inherit` is unchanged. This is a dispatch rule, not a model swap.
* The rule is instruction-level: no hook can force the call, so the report should
  say whether the external call happened and what it contributed.

## Consequences

* Every role spends one external CLI call per task, consuming the provider's quota
  and adding latency. The external CLI must be installed and authenticated; a
  missing CLI triggers the documented fallback.
* The host model still receives the subagent prompt and issues the wrapper command;
  it cannot literally start on the external model. The external model's context is
  limited to the prompt, but because it inherits the cwd and has its own tools, it
  can read the repository itself.
* The external CLI runs outside the Claude PreToolUse hooks (ADR 0010, ADR 0003):
  a role's write/Bash restrictions are instruction-only inside that turn.
* `pullo` now has an executor route; cross-role denials still apply to it.

## Links

* Supersedes: [0008](0008-default-external-cli-routes.md) (the optional-consultation
  wording and the pullo-unmapped clause)
* Still in force: [0015](0015-anthory-default-orchestrator-neon-route.md),
  [0010](0010-cli-routes-workspace-write.md),
  [0003](0003-enforcement-boundary-and-accepted-residual-risk.md)
* Implementation: `mark.md`, `octavion.md`, `posca.md`, `atia.md`,
  `vorenus.md`, `anthory.md`, `pullo.md`, `hooks/lib/executor.sh`, `AGENTS.md`
