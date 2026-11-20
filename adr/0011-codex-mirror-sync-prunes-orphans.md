---
status: accepted
date: 2026-11-20
supersedes: 0004 (--check semantics), 0006 (stale-mirror consequence)
---

# Codex mirror sync prunes orphan mirrors and `--check` fails on them

## Context and Problem Statement

ADR 0004 named `scripts/sync-codex-mirror.sh` the generator of the
`~/.codex/agents/*.toml` mirrors and said `--check` exits non-zero when a mirror is
older than its source. ADR 0006 recorded the consequence as: "`~/.codex/agents` still
contains the six legacy TOMLs; `scripts/sync-codex-mirror.sh` regenerates named
mirrors but does not delete orphans. Cleaning them requires explicit authorization."

Both statements are now false. Commit `220cd79` made pruning part of a normal sync:
any `*.toml` with no row in `tests/fixtures/agent-contract.tsv` is removed with
`rm -f` and reported as `pruned <name>`, and `--check` reports it as `ORPHAN` and exits
1. `~/.codex/agents/` now holds exactly the seven current mirrors; the legacy TOMLs
are gone because that run deleted them.

What is the authoritative mirror lifecycle?

## Considered Options

* **Regenerate only; leave orphan mirrors for a human to remove.** Rejected: a retired
  agent whose mirror survives stays dispatchable by Codex, which is exactly the drift
  ADR 0004 exists to stop.
* **Regenerate and prune in one sync, with `--check` failing on both stale and
  orphaned mirrors.** Chosen.
* **A separate cleanup command.** Rejected: it adds a second step that can be
  forgotten, and pruning is the same "keep the two runtimes in agreement" operation
  as regeneration.

## Decision Outcome

Chosen option: **"Regenerate and prune in one sync."**

* A normal run rewrites stale mirrors and deletes any `*.toml` with no contract row,
  reporting `pruned <name>`; the summary reads `<n> regenerated, <m> pruned`.
* `--check` prints `ORPHAN <name>` for each mirror with no contract row and exits 1
  when any mirror is stale **or** orphaned.
* Retiring an agent from Codex is therefore done by removing its contract row and
  running the sync; there is no separate manual cleanup step.

### Consequences

* Good, because a retired agent's mirror cannot silently stay dispatchable.
* Good, because `--check` in preflight now covers both failure modes.
* Bad, because deleting a contract row removes that agent's mirror on the next sync;
  the row is the single switch for both runtimes.
* Neutral, because the mirror remains machine-local, generated state under
  `~/.codex/`, never committed.

## Links

* Supersedes: [0004](0004-codex-toml-mirror-is-a-build-artifact.md) (`--check`
  semantics), [0006](0006-7-role-bash-authorization.md) (stale-mirror consequence)
* Implementation: `scripts/sync-codex-mirror.sh` (prune loop and `--check` exit),
  commit `220cd79`
* Documentation: `AGENTS.md` "Orphan mirrors"
