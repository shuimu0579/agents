---
status: accepted
date: 2026-11-23
supersedes: 0008 (anthory route only)
---

# Default agy Orchestrator (Neon) route for anthory

## Context and Problem Statement

ADR 0008 gave five roles a default external model and left `anthory` and `pullo`
on the host session model. The user now wants `anthory` to default to agy
**Orchestrator (Neon)** (`gemini-pro-orchestrator-neon`), the same model `vorenus`
already uses.

`Orchestrator (Neon)` is an agy model ID, not a Claude Code model ID. Claude Code's
`model:` field cannot carry it, and the fleet contract pins `model: inherit` for all
seven agents; changing the contract column would also make the subagent fail to
resolve. The only route that reaches the model is the pinned wrapper,
`tools/agent-cli.sh`. ADR 0008 explicitly denied that wrapper to `anthory`, so a
gate change is required. The user was asked whether that gate widening was
acceptable and approved the bound route (2026-11-23).

## Decision Drivers

* The user asked for Orchestrator (Neon) as anthory's default (2026-11-23).
* The wrapper must remain the single admitted shape; raw `agy`/`codex`/`grok`
  execution would be an arbitrary-execution grant (ADR 0008).
* The route stays bound to the attributed `agent_type`: anthory must not reach
  another role's route, and no other role may reach anthory's.
* `pullo` stays unmapped; this ADR does not widen any other role.

## Considered Options

* **Change `model:` in `anthory.md` to the agy ID.** Rejected: Claude Code cannot
  resolve an agy model ID from `model:`, and the contract's `inherit` invariant
  would fail guardrails.
* **Let anthory call `agy` directly.** Rejected: no fixed flags, no hash pin, and
  it re-opens the gap ADR 0008 closed.
* **Add a bound `anthory` route in `exec_agent_cli_route`.** Chosen.

## Decision Outcome

* `hooks/lib/executor.sh` maps `anthory` to `agy|gemini-pro-orchestrator-neon` and
  lists it in `exec_agent_cli_roles`.
* The existing gate helpers carry the route with no new code: `exec_is_agent_cli`
  already requires `role == caller` and a mapped role, so
  `bash /Users/suimu/.claude/agents/tools/agent-cli.sh anthory "<prompt>"` is
  admitted, while cross-role calls and `sh` are still denied with `rule:allowlist`.
* The wrapper's CLI pin, model, safety flags, prompt channel and prompt validation
  are unchanged. `pullo` remains unmapped and is still denied its own route.
* `model: inherit` stays in the contract and in `anthory.md`; the external model is a
  dispatch route, not an agent-definition model.

## Consequences

* Accepted risk (ADR 0010, ADR 0003): each admitted call gives `anthory` one
  non-interactive `agy` turn with `--sandbox` workspace-write isolation. That turn
  runs outside the Claude PreToolUse hooks: the Write/Edit self-protection that
  denies attributed agents `hooks/`, `tests/`, `tools/`, `scripts/`, root `*.md`
  and `.git` does not run inside it, nor does the Bash allowlist. When the invoking
  cwd is the fleet root, the turn can rewrite those paths — including
  `tools/agent-cli.sh` and `tools/cli-sha256` — and `.git/hooks`, and can run
  commands the Claude allowlist would deny, bounded only by the vendor sandbox.
  This is the same residual ADR 0010 records for `vorenus` (same backend and model);
  `anthory`'s standing git authority already lets it alter tracked files, so the
  delta is direct writes and `.git/hooks`, not net-new repository authority. The
  prompt is passed as `--print=<prompt>` and is visible in same-user process
  listings (ADR 0008, audit B12).
* Combination risk: `anthory` already holds standing `git push`/`reset --hard`/
  `clean` (ADR 0007). With this route, one session can have an external agy turn
  produce changes, `anthory` write them, and `anthory` push them without a separate
  independent review gate. This is a combination of existing authorities, not a new
  grant; workflows that require independent review must still route implementation
  through `vorenus` and review through `posca`.
* Tests change from asserting `anthory` is unmapped to asserting its own route is
  admitted and its dispatched argv names Orchestrator (Neon).
* ADR 0008's table remains historical for the other roles; only its anthory clause
  is superseded.

## Links

* Partially supersedes: [0008](0008-default-external-cli-routes.md)
* Still in force: [0007](0007-orchestrator-standing-git-authority.md),
  [0010](0010-cli-routes-workspace-write.md),
  [0003](0003-enforcement-boundary-and-accepted-residual-risk.md)
* Implementation: `hooks/lib/executor.sh`, `tools/agent-cli.sh`,
  `anthory.md`, `AGENTS.md`, `tests/hooks.test.sh`
