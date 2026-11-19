---
status: accepted
date: 2026-08-26
---

# Restore `_xixi` as an active fleet agent

## Context and Problem Statement

The 2026-08-09 Codex+Grok fleet consolidation archived six agents (`planner`, `build-error-resolver`, `tdd-guide`, `refactor-cleaner`, `doc-updater`, `_xixi`) per Codex audit recommendation D1. The two auditors split on `_xixi` specifically: Codex's D1 (`docs/audits/codex-grok-audit-2026-08-09.md:85`) argued to delete the agent and fold prompt refinement into an ordinary skill, since "clipboard side-effect complexity >> value." Grok's counter-position in the same audit argued to keep it, since its clipboard delivery + Write sandbox is "the fleet's only special pipeline" (剪贴板交付 + Write 沙箱是全队唯一特殊管线).

Should `_xixi` stay archived (deleted as an agent, reimplemented as a plain skill), or be restored to the active fleet?

## Considered Options

* Keep `_xixi` archived; reimplement prompt refinement as an ordinary skill with no dedicated Write sandbox or clipboard hook (Codex D1)
* Restore `_xixi` as an active agent with a hardened Write sandbox and dedicated clipboard-delivery hooks (Grok counter-position)
* Leave it archived permanently with no replacement (status quo, not argued for by either auditor)

## Decision Outcome

Chosen option: "Restore `_xixi` as an active agent with a hardened Write sandbox," because the clipboard-delivery + sandboxed-Write pipeline is infrastructure a plain skill cannot reproduce, and it is the only agent in the fleet with that shape. The restoration (commits `22544dc`, `f8d291f`, `c7b01f2`) re-registered `_xixi` in the fleet contract, fail-closed the `/tmp` delivery path (deny pre-existing targets, exclusive reserve, nlink/uid checks), and added isolated hook CI coverage before re-activation.

### Consequences

* Good, because prompt refinement keeps a reliable delivery path (system clipboard) that a plain skill cannot offer
* Good, because the fleet's write-capability isolation model (`hooks.md` / `agents.md` mutator mutex) already had a slot reserved for a sandboxed, non-repo mutator — `_xixi` fills it cleanly
* Bad, because it keeps a second write-capable code path in the fleet that guardrails/tests must track (agent-contract fixtures, `restrict-write.sh`, `copy-on-write.sh`) instead of the simpler zero-Write skill Codex proposed
* Neutral, because Codex's broader D1 (delete 5 other agents) still stands; only the `_xixi` row was overridden

### Confirmation

* `_xixi.md` is listed under Active Agents in `AGENTS.md` / `CLAUDE.md`, not under Archived
* `hooks/xixi/restrict-write.sh` and `hooks/xixi/copy-on-write.sh` exist and are covered by `tests/xixi-hooks.test.sh`
* `tests/fixtures/agent-contract.tsv` carries a `_xixi` row so `tests/guardrails.sh --strict` fails if the agent and its contract drift apart
