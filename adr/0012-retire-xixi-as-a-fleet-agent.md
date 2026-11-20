---
status: accepted
date: 2026-11-20
supersedes: 0001
---

# Retire `_xixi` as a fleet agent

## Context and Problem Statement

ADR 0001 restored `_xixi` as an active agent with a hardened Write sandbox and
clipboard-delivery hooks. Its Confirmation section required `_xixi.md` to be listed
under Active Agents and a `_xixi` row in `tests/fixtures/agent-contract.tsv`.

Neither holds now. The fleet is a 7-role roster (`anthory`, `mark`, `octavion`,
`posca`, `atia`, `vorenus`, `pullo`); there is no `_xixi.md`, and the contract table
has no `_xixi` row. The two hooks still exist and remain registered in Claude Code,
but they are inert for every other identity: they act only when the host stamps
`agent_type` or `subagentType` as `_xixi` or `xixi`.

Should `_xixi` be restored to the roster again, or recorded as retired with its hooks
kept as a historical compatibility surface?

## Considered Options

* **Restore `_xixi` as an active agent again.** Rejected: the roster and contract have
  already dropped it, and no current role needs the pipeline.
* **Delete the hooks as well.** Rejected: they are registered, covered by
  `tests/xixi-hooks.test.sh`, and inert for other identities; removing them is a
  separate hooks change, not required to record the retirement.
* **Record `_xixi` as retired; keep the hooks registered and inert, documented as a
  historical compatibility surface.** Chosen.

## Decision Outcome

Chosen option: **"Retired, hooks kept as historical compatibility."**

* The fleet roster stays at seven agents; `_xixi` has no definition file and no
  contract row.
* `hooks/xixi/restrict-write.sh` and `hooks/xixi/copy-on-write.sh` remain registered
  in Claude Code (`~/.claude/settings.json`) and are inert for every other identity.
  On this machine Grok registers none: `~/.grok/hooks/agent-gates.json` is absent and
  `~/.grok/config.toml` sets `hooks = false`.
* `hooks/xixi/CONTRACT.md` is the historical interface record; it is not a live agent
  contract.

### Consequences

* Good, because ADR 0001 no longer reads as a current description of the fleet.
* Good, because removing the hooks is not required to retire the identity; the
  registration can be revisited separately.
* Bad, because the mutator sandbox slot ADR 0001 reserved is no longer filled by a
  live role; the general mutator property is covered by the contract `mutator` flag
  and the synthetic `probe-mutator` row in `tests/hooks.test.sh`.
* Neutral, because the hooks stay registered and are inert unless a host stamps the
  `_xixi` identity.

## Links

* Supersedes: [0001](0001-restore-xixi-as-active-agent.md)
* Historical interface: `hooks/xixi/CONTRACT.md`
* Boundary: `AGENTS.md` "`_xixi` Write boundary (historical)"
