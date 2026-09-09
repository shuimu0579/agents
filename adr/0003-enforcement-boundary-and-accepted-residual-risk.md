---
status: accepted
date: 2026-09-09
---

# The hook layer is an authorization gate, not a sandbox

## Context and Problem Statement

`AGENTS.md` requires structural choices to be recorded, but the shared-hook architecture
and its approval trust model were never given an ADR. The 2026-09-09 audit found six
Critical findings, and the deeper problem was not any single regex: the repository
described itself as a security-enforced system without stating what the enforcement
actually guarantees. Reviewers and future maintainers had no written boundary to hold
changes against, so each hardening pass argued from scratch.

What does this hook layer actually promise, and what must be accepted as out of scope?

## Considered Options

* Leave the guarantee implicit and keep hardening case by case (status quo)
* Claim full sandboxing and pursue OS-level isolation for every agent capability
* State the boundary explicitly as an authorization gate, and record what it does not cover

## Decision Outcome

Chosen option: **"State the boundary explicitly as an authorization gate."**

The hooks are a **PreToolUse authorization gate**. They decide whether a tool call is
permitted, using only what the host hands them: an event payload naming an agent, a
command or a path. That is the whole mechanism, and three properties follow from it.

**It is an allowlist, and it fails closed.** An unreadable contract, a missing `jq`, a
payload that is not an event object, a path that cannot be normalized, or a command that
cannot be tokenized unambiguously all deny. Denial is the default; permission is the
exception that must be proven.

**It authorizes argv, not strings.** `sec_cmd_tokenize` performs shell quote removal
exactly once and refuses any syntax it cannot resolve — command substitution, pipes,
redirection, `;`, `&&`, unbalanced quotes, expandable globs. Every policy consumes the
resulting `SEC_ARGV`. Deciding safety by matching the raw command string was the single
root cause behind findings #1, #2, #3 and #10 (ADR 0002 context, commit `3f66bdc`).

**Capability is derived, never separately declared.** Bash authority comes from the
agent's declared tool set in `tests/fixtures/agent-contract.tsv`, which
`guardrails.sh --strict` validates against the agent files. Hand-maintained parallel
flags drift; a derived value cannot disagree with its source.

### Consequences

* Good, because "is this denied by default?" becomes an answerable question for any new
  code path, instead of a judgement call per reviewer
* Good, because the fail-closed rule makes dependency loss safe rather than silently permissive
* Bad, because fail-closed means a broken `jq` install stops attributed agents entirely
* Bad, because tokenizing conservatively rejects some legitimate commands (quoted `$`,
  parentheses in a git format string). That is the intended trade for an allowlist
* Neutral, because the main session is deliberately unconstrained — these hooks govern
  attributed subagents, not the human at the keyboard

### Accepted residual risk

These are **not** covered, and no test in this repository can detect them:

* **Attribution is the host's job.** If the harness omits `agent_type` on a subagent
  event, the gate treats it as main session and passes it through. Every suite stays
  green. `hooks/xixi/CONTRACT.md` carries the manual verification procedure.
* **The gate authorizes; it does not contain.** Once a command is allowed, the process
  runs with the user's full privileges. ADR 0002 removed `Bash` from `e2e-runner`
  precisely because no gate can constrain code that an allowed process then executes.
* **Write/Edit protection is path-based, at the tool boundary.** It cannot intercept
  filesystem calls made by a process the gate already allowed.
* **TOCTOU is narrowed, not closed.** The Write API exposes no `O_NOFOLLOW`.
* **Approval tokens carry no operation binding** (audit #21, still open in P3): they are
  named `with-deps` / `snapshots` and a concurrent run can consume one intended for
  another operation.

### Confirmation

* `tests/p1-bypass.test.sh` — 19 probes, each asserting a denial the gate once failed to make
* `tests/hooks.test.sh` — asserts *why* a command was denied (`bt_rule`), not merely that it was
* `guardrails.sh --strict` — agent files match the contract that Bash authority derives from
* Every fail-closed path above has a probe; removing the check turns its probe red
