---
status: accepted
date: 2026-11-20
supersedes: 0006, 0007 and 0010 (protected Markdown scope wording only)
---

# Protect Markdown files at any depth under the fleet root

## Context and Problem Statement

The 2026-11-20 full-chain test wrote its ledger as a `.ledger` file after
`rule:self-protect` denied the original nested `.md` path. The hook uses the shell
`case` pattern `"${fleet_root_cf}/"*.md`. The `*` can match `/`, so the pattern
covers Markdown files at every depth under the fleet root. This also protects
`docs/agent-output-contract.md`, a policy file that must stay protected.

## Considered Options

* **Restrict the hook to root-level Markdown.** Rejected because this would expose
  nested policy documents to agent Write/Edit.
* **Update the live documentation to match the hook.** Chosen.
* **Leave the discrepancy.** Rejected because the documented scope would continue
  to mislead agents planning where to write files.

## Decision Outcome

Write/Edit self-protection intentionally covers any `*.md` under the fleet root
at any depth. `AGENTS.md` and `anthory.md` now describe this scope. The hook
remains unchanged.

The decisions in ADRs 0006, 0007 and 0010 stand. This ADR supersedes only their
inaccurate phrase “root `*.md`” describing the protected Markdown scope.

### Consequences

* Agents subject to the gate cannot Write/Edit any `.md` under the fleet root.
  They can use a `.ledger` file or another non-`.md` path where writes are allowed.
* The documentation correction requires no test changes.
