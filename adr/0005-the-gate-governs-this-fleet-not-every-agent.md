---
status: accepted
date: 2026-09-10
supersedes: 0003 (scope wording only)
---

# The Bash gate governs this fleet, not every agent on the machine

## Context and Problem Statement

`restrict-bash-by-agent.sh` is registered in the user's **global** `~/.claude/settings.json`
under `PreToolUse`/`Bash`. It therefore runs for every Bash call by every subagent, in
every project on this machine. Its policy lookup reads a six-row fleet contract, and
anything absent from it was denied with `rule:unknown-agent`.

Measured on this machine: 6 fleet agents are in the contract, ~270 plugin agent
definitions are installed, and Claude Code ships its own built-ins — `general-purpose`,
`Explore`, `Plan`, `code-review`, `statusline-setup` and more. Every one of them except
the six was denied Bash.

This is not hypothetical. A code review of this repository was degraded to file-reading
only because `git` was denied; it read the wrong tree and produced findings whose line
numbers referred to a different commit.

ADR 0003 states the design principle as deny-by-default, fail closed. That principle was
written for agents this fleet defines and hands a tool set to. Should it also govern
agents the fleet did not create and has no policy for?

## Considered Options

* **Deny unknown agents** (status quo)
* **Abstain on unknown agents** — the gate governs the fleet; everything else is the host's
* **Allowlist known non-fleet agents in the contract**
* **Scope the hook to this repository** — pass through outside the fleet root
* **A restricted command fallback** for unknown agents

## Decision Outcome

Chosen option: **"Abstain on unknown agents, after validating that scope can be
established."**

The boundary follows the agents this repository governs, wherever they work. Global
registration is right for that purpose; global ownership of every agent's Bash policy is
not. Codex deliberated this (thread `01a089bb`) and made the point that decided it: the
status quo offers **broader denial, not stronger safety**. It leaves the gaps ADR 0003
already records untouched — main-session execution, host-controlled attribution — while
imposing a real reliability cost.

Naively flipping the empty-policy branch to success would have been wrong, because a
lookup returning nothing has three causes the code could not distinguish:

| Cause | Correct response |
|---|---|
| The identity has no definition in this fleet | Out of scope — abstain |
| A fleet agent's contract row was deleted | Contract damaged — deny |
| The contract is empty, truncated or malformed | Scope unknowable — deny everything attributed |

Two preconditions now guard abstention:

1. **The contract must be usable.** At least one well-formed five-field row, or every
   attributed call is denied (`rule:contract-unusable`).
2. **The identity must have no fleet definition on disk.** `<name>.md` present at the
   fleet root without a contract row is damage, not an external agent
   (`rule:contract-incomplete`). This is a single `stat`, deliberately not a directory
   scan — the check runs on the PreToolUse hot path for every Bash call on the machine.

Abstention means **the hook makes no authorization decision**. It exits 0 and records
`decision=abstain` in the audit log; whatever the host permits for that agent still
applies. It is not a grant, and it does not override host controls.

### Consequences

* Good, because agents the fleet never defined stop being broken by a policy that has
  nothing to say about them, and newly installed plugins are not silently crippled
* Good, because the fleet's own guarantee is unchanged and now tested from outside the
  repository as well as inside
* Good, because contract damage is louder than before: two distinct rules name it,
  where previously it was indistinguishable from an unknown name
* Bad, because external agents regain whatever Bash authority the host permits. The
  incidental protection against a compromised or prompt-injected plugin agent is gone
* Neutral, because that protection was never designed — it was a side effect of a fleet
  contract being consulted for identities it does not describe

### Relationship to ADR 0003

This **supersedes ADR 0003's scope wording only**. That ADR states an unqualified
fail-closed rule; the rule now reads: *fail closed within fleet scope, and whenever scope
cannot be established; abstain on validated external identities.* Everything else in
ADR 0003 — argv-not-strings, capability derived from the declared tool set, and the
accepted residual risks — stands unchanged.

Calling this an implementation clarification would be inaccurate. It is a narrowing of
what the gate claims to protect.

### Accepted residual risk

* **Attribution stays host-controlled.** A missing `agent_type` already bypassed
  enforcement; now an incorrect external identity would bypass fleet policy too. The gate
  cannot verify who it is talking to.
* **Name matching establishes no provenance.** An external agent that happens to share a
  fleet name is still restricted, which is the safe direction, but a namespaced or
  aliased fleet identity would need separate handling.
* **No containment against other processes.** Anything running as this user can modify
  the enforcement files themselves; tool-level Write/Edit guards do not intercept a
  process's own filesystem calls.

The retained guarantee is precise: **correctly attributed fleet Bash calls are denied
everywhere, while the enforcement layer is intact.**

### Confirmation

`tests/p3-gate-scope.test.sh` — 18 probes, in `run_all.sh`:

* each of the six fleet agents denied both inside and outside the repository
* six external identities abstained on, including a Claude Code built-in, an installed
  plugin agent, and a name that exists nowhere
* a deleted contract row, an empty policy field, an empty contract and an unreadable
  contract all deny — abstention is unreachable through contract damage
* the main session, which carries no `agent_type`, is unaffected
