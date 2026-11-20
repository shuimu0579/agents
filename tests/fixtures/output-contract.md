---
description: "Canonical severity scale, verdict vocabulary, and report skeleton for the 7-role fleet. Referenced by agents/*.md to stay in sync."
---

# Agent Output Contract (canonical)

> Single source of truth for severity definitions, the orchestrator-facing verdict
> vocabulary, and the report skeleton. Agent prompts say "Severity and verdict follow
> `~/.claude/agents/docs/agent-output-contract.md`" rather than re-declaring them (grill F16).
> The **Verdict mapping** table lets a meta-orchestrator normalize any agent's domain
> status to the canonical `Verdict` below.

## Severity scale

Every finding MUST carry one severity and these fields:

| Severity | Meaning | SLA |
|----------|---------|-----|
| **CRITICAL** | Exploitable / data loss / prod outage / secret leak. Blocks merge. | Fix before merge, rotate exposed secrets now. |
| **HIGH** | Likely bug or security weakness under realistic conditions. | Fix this sprint, before prod. |
| **MEDIUM** | Correctness/maintainability issue with bounded impact. | Fix next sprint. |
| **LOW** | Polish, style, opportunistic cleanup. | Fix when touching the file. |

Required per-finding fields: `File: path:line` · `Summary` · `Failure/exploit scenario` (concrete inputs → wrong outcome) · `Fix` · `Effort` · `Impact` · `Verify after fix`.

## Verdict vocabulary (orchestrator-facing)

Every agent report ends with exactly one canonical verdict line:

```
**Verdict:** GO | BLOCK | NEEDS_INPUT
```

- **GO** — safe to proceed / merge / ship.
- **BLOCK** — must not proceed; CRITICAL/HIGH unresolved.
- **NEEDS_INPUT** — blocked on a decision or missing info from the orchestrator/user.

Agents ALSO emit a domain sub-status. The Verdict mapping below normalizes every
domain status to one canonical verdict. Match tokens exactly; `BLOCKED_QUOTA` is not
`BLOCKED`, and `PASS_WITH_RISKS` is not `PASS`.

## Active fleet (7 roles)

`anthory`, `mark`, `octavion`, `posca`, `atia`, `vorenus`, `pullo`.

The six legacy roles (`architect`, `code-reviewer`, `security-reviewer`,
`e2e-runner`, `_xixi`, `_critical_thinking`) are retired. Their definitions and
contract rows are gone; an identity with neither a `.md` nor a contract row is
out of this gate's scope (ADR 0005).

## Verdict mapping (domain status → canonical)

| Agent | Domain status | → Canonical |
|-------|---------------|-------------|
| anthory | DELIVERED | GO |
| anthory | BLOCKED | BLOCK |
| anthory | NEEDS_INPUT | NEEDS_INPUT |
| mark | ACCURATE | GO |
| mark | NEEDS_CORRECTION | NEEDS_INPUT |
| mark | NEEDS_CLARIFICATION | NEEDS_INPUT |
| octavion | PLAN_READY | GO |
| octavion | BLOCKED | BLOCK |
| octavion | NEEDS_INPUT | NEEDS_INPUT |
| posca | PASS | GO |
| posca | PASS_WITH_RISKS | NEEDS_INPUT |
| posca | FAIL | BLOCK |
| atia | ON_TRACK | GO |
| atia | DEVIATED | NEEDS_INPUT |
| atia | BLOCKED | BLOCK |
| atia | INSUFFICIENT_EVIDENCE | NEEDS_INPUT |
| vorenus | PASS | GO |
| vorenus | FAIL | BLOCK |
| vorenus | BLOCKED_QUOTA | NEEDS_INPUT |
| pullo | PASS | GO |
| pullo | FAIL | BLOCK |
| pullo | BLOCKED | BLOCK |

## Report skeleton (required)

```markdown
# <Agent> Report
**Domain status:** <agent-specific token>
**Scope:** <exact paths and/or a stable scope identifier — a commit SHA, a dispatcher-provided patch hash, a base/head pair, or paths + a diff snapshot timestamp. GO MUST bind to this identifier. A SHA is preferred but is not always available: an uncommitted working-tree review has none.>

## Findings
- [SEVERITY] File: path:line — <summary>
  - Scenario: <concrete failure/exploit>
  - Fix: <action>
  - Effort: <S/M/L> · Impact: <scope> · Verify: <how>

## Good
- <strengths to preserve>

## Handoff
- Next owner and any pending decision

**Verdict:** GO | BLOCK | NEEDS_INPUT
```

## Handoff adjacency

```
main session → mark (intent check) → octavion (plan) → posca (plan review)
  → vorenus (execute; pullo only when vorenus is explicitly out of quota)
  → posca (result review + ledger) → anthory (summary to the user)
atia (process spot check) runs on demand, not as a mandatory step
```

Independent review-only tasks may run in parallel. Dependent steps follow the
arrow order above.

## Mutator mutex

- Repo mutator (primary): `vorenus` (Read, Write, Edit, Bash, Grep, Glob). Only one repo mutator instance runs at a time.
- Repo mutator (fallback): `pullo` (Read, Write, Edit, Bash, Grep, Glob) — only when `vorenus` is explicitly out of quota. Never take over on an ordinary timeout or error.
- Ledger writer: `posca` (Read, Write, Edit, Bash, Grep, Glob) writes audit records only, not implementation.
- Review roles (no Write/Edit; Bash only for `tools/agent-cli.sh`, may run in parallel): `mark` (Read, Grep, Glob, Bash), `octavion` (Read, Grep, Glob, Bash), `atia` (Read, Grep, Glob, Bash).
- Orchestrator: `anthory` (Read, Write, Edit, Bash, Grep, Glob, Agent) — executor allowlist plus standing git write authority including `push`/`reset --hard`/`clean` (ADR 0007). Not a repo mutator: implementation still goes to `vorenus`/`pullo`.

Every tool list above restates column 2 of `tests/fixtures/agent-contract.tsv`;
that column is authoritative if the two ever disagree.
