---
description: "Canonical severity scale, verdict vocabulary, and report skeleton for all specialist agents. Referenced by agents/*.md to stay in sync."
---

# Agent Output Contract (canonical)

> Single source of truth for severity definitions, the orchestrator-facing verdict
> vocabulary, and the report skeleton. Agent prompts say "Severity and verdict follow
> `~/.claude/agents/docs/agent-output-contract.md`" rather than re-declaring them (grill F16).
> A future full standardization (grill F14) renames every agent's domain token to the
> canonical `Verdict` below; until then, the **Verdict mapping** table lets a
> meta-orchestrator normalize any agent's domain status.

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

Agents ALSO emit a domain sub-status (the tokens the fleet already uses). The two reviewers'
`BLOCK | APPROVE WITH CHANGES | APPROVE` is the seed of this contract.

## Verdict mapping (domain status → canonical)

Until full rename (F14), map each agent's existing token to the canonical verdict.
Guardrails match exact rows of the form `| <agent> | <token> |` (optional backticks around the token).

| Agent | Domain status | → Canonical |
|-------|---------------|-------------|
| architect | RECOMMEND | GO |
| architect | OPTIONS | NEEDS_INPUT |
| architect | BLOCKED | BLOCK |
| code-reviewer | APPROVE | GO |
| code-reviewer | APPROVE WITH CHANGES | NEEDS_INPUT |
| code-reviewer | BLOCK | BLOCK |
| security-reviewer | APPROVE | GO |
| security-reviewer | APPROVE WITH CHANGES | NEEDS_INPUT |
| security-reviewer | BLOCK | BLOCK |
| e2e-runner | PASSING | GO |
| e2e-runner | QUARANTINE | NEEDS_INPUT |
| e2e-runner | FAILING | BLOCK |
| _xixi | ✅ copied | GO |
| _xixi | ⚠️ failed | NEEDS_INPUT |
| _critical_thinking | SOUND | GO |
| _critical_thinking | INCOMPLETE | NEEDS_INPUT |
| _critical_thinking | UNSOUND | BLOCK |

> **Active fleet:** `architect`, `code-reviewer`, `security-reviewer`, `e2e-runner`, `_xixi`, `_critical_thinking`.  
> **Archived 2026-08-09 (reference only):** `planner`, `tdd-guide`, `refactor-cleaner`, `build-error-resolver`, `doc-updater` live in the main session — not part of this fleet.

## Report skeleton (recommended)

```markdown
# <Agent> Report
**Verdict:** GO | BLOCK | NEEDS_INPUT
**Domain status:** <agent-specific token>
**Scope:** <exact paths / diff SHA — APPROVE MUST be bound to the reviewed SHA (grill F24)>

## Findings
- [SEVERITY] File: path:line — <summary>
  - Scenario: <concrete failure/exploit>
  - Fix: <action>
  - Effort: <S/M/L> · Impact: <scope> · Verify: <how>

## Good
- <strengths to preserve>

## Handoff
- Next owner per `rules/agents.md` pipeline
```

## Handoff adjacency

```
architect (design) → main session / implementer (implementation)
  → code-reviewer (review) → main session / implementer (fixes)
  → code-reviewer (same-scope re-review)
  → security-reviewer (if auth/input/payment touched)
  → e2e-runner (E2E, before merge)
  → code-reviewer (same-scope final review when e2e-runner changed specs)

_xixi (prompt refinement) is independent of the merge pipeline; hand off to the user (clipboard or paste fallback).
_critical_thinking (inquiry) is independent of the merge pipeline; hand off to the user, or to architect / code-reviewer / security-reviewer when the now-examined question belongs there.
```

## Mutator mutex

- Repo mutator: `e2e-runner` (Read, Write, Edit, Bash, Grep, Glob). Only one **repo** mutator instance runs at a time.
- Sandbox mutator: `_xixi` (Read, Grep, Glob, Write) — Write only to `/tmp/xixi-prompt-<8-alnum>`; may run in parallel with review-only agents.
- Review-only agents (`architect`, `code-reviewer`, `security-reviewer`, `_critical_thinking`) may run in parallel with each other and with at most one `e2e-runner`.
