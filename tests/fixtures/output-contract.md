# Agent Output Contract

Canonical orchestrator-facing verdict vocabulary shared by all agents. **Single source of truth** — `~/.claude/rules/agents.md` references this file for verdict mapping; agent prompts mirror it.

## Verdict (required — final line)

Every agent MUST emit exactly one `**Verdict:**` line as the **final line** of its report, using GO | BLOCK | NEEDS_INPUT:

- `**Verdict:** GO` — work complete, safe to proceed
- `**Verdict:** BLOCK` — cannot proceed because an established error, failed check, or security finding blocks progress
- `**Verdict:** NEEDS_INPUT` — missing input, human decision, or orchestrator action is required

## Domain Status Tokens

Each agent maps its domain-specific status to a canonical verdict:

| Agent | Domain Token | → Verdict |
|-------|-------------|-----------|
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
| e2e-runner | QUARANTINE | NEEDS_INPUT (flaky, explicit accept) |
| e2e-runner | FAILING | BLOCK |

## Report Skeleton

Every agent report includes:
1. **Scope** — what was examined
2. **Findings/Results** — what was discovered
3. **Handoff** — next step per `~/.claude/rules/agents.md` pipeline
4. **Verdict** — GO | BLOCK | NEEDS_INPUT (final line)

## Handoff Adjacency

```
architect (design) → main session / implementer (implementation)
  → code-reviewer (review) → main session / implementer (fixes)
  → code-reviewer (same-scope re-review)
  → security-reviewer (if auth/input/payment touched)
  → e2e-runner (E2E, before merge)
  → code-reviewer (same-scope final review when e2e-runner changed specs)
```

Roles retired 2026-08-09 (planner / tdd-guide / build-error-resolver / refactor-cleaner / doc-updater / _xixi) live in the main session or as skills; they are not part of this fleet.

## Mutator Mutex

- Sole mutator: `e2e-runner` (Read, Write, Edit, Bash, Grep, Glob). Only one mutator instance runs at a time.
- Review-only agents (`architect`, `code-reviewer`, `security-reviewer`) may run in parallel with each other and with at most one `e2e-runner`.
