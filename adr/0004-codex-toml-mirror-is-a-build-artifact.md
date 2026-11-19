---
status: accepted
date: 2026-09-09
---

# The Codex TOML mirror is a generated build artifact

## Context and Problem Statement

`AGENTS.md` said "there is no build or compile step" while also stating that Codex loads
a generated `~/.codex/agents/*.toml` mirror. Both cannot be true. No generator, sync
command, or drift check was tracked anywhere in the repository.

The cost was not theoretical. On 2026-09-09 three mirrors — `e2e-runner`,
`code-reviewer`, `security-reviewer` — were still carrying pre-ADR-0002 bodies. A
Codex-dispatched `e2e-runner` was reading an agent definition that told it to run
`playwright test --base-url=<literal>`, five days after `Bash` had been removed from it
and every such invocation had been deleted from the source. The security decision had
reached one runtime and not the other, and nothing reported that.

## Considered Options

* Keep hand-editing both copies (status quo — already demonstrably drifted)
* Drop the mirror and give up Codex-side dispatch
* Track a generator plus a drift check, and name the mirror a build artifact

## Decision Outcome

Chosen option: **"Track a generator plus a drift check."** `scripts/sync-codex-mirror.sh`
renders each `<name>.toml` from `<name>.md` — frontmatter `description` and body become
`description` and `developer_instructions` — driven by `tests/fixtures/agent-contract.tsv`
so the mirror covers exactly the fleet the contract defines. `--check` exits non-zero
when any mirror is older than its source.

Claude Code still needs no build step; it reads the `.md` files directly. The claim was
only ever wrong for Codex, and `AGENTS.md` now says so.

### Consequences

* Good, because a security change to an agent body can no longer reach one runtime and
  silently miss the other
* Good, because `--check` makes the drift visible in preflight rather than at dispatch time
* Bad, because agent edits now have a required follow-up step; forgetting it reintroduces
  exactly the drift this ADR exists to stop, which is why `--check` belongs in preflight
* Neutral, because the mirror stays outside the repository — it is machine-local state
  under `~/.codex/`, generated, never committed

### Why `--check` is not in `run_all.sh`

A machine that only uses Claude Code has no `~/.codex/agents/` at all. Failing the suite
there would punish a valid configuration and train people to ignore the check. It is a
preflight and post-edit step, listed under Prerequisites in `AGENTS.md`.

### Confirmation

* `bash scripts/sync-codex-mirror.sh --check` reports `all mirrors current`
* Regenerated mirrors parse as TOML and carry the post-ADR-0002 bodies: `base-url`
  appears 0 times in `e2e-runner.toml`, and both reviewers carry their evidence gates
* Bodies are emitted as TOML **literal** multi-line strings, which process no escapes.
  Agent bodies contain backslash sequences inside example prompts; a basic string would
  require escaping them and silently change the text the agent receives. Verified: all
  six `developer_instructions` are byte-identical to their source bodies
* The generator does **not** rewrite `~/.claude/agents/...` to `~/.Codex/agents/...`, which
  whatever produced the pre-existing mirrors did. That rewrite pointed at paths that do
  not exist — `~/.codex/agents/` holds only the mirrors, not `docs/` or `templates/` —
  so the referenced files were unreachable from a Codex session
* `--check` compares CONTENT, not mtime. A test that edits a definition and restores it
  bumps the mtime without changing a byte, and an mtime check then reports a mirror as
  stale when it is identical to what would be generated
