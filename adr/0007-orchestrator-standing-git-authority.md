---
status: accepted
date: 2026-11-20
supersedes: 0006 (orchestrator role only)
---

# Standing git write authority for the orchestrator role

## Context and Problem Statement

Anthory coordinates the fleet but could not read or write git state: it is
`review_only`, so the Bash gate denies it outright (ADR 0006). Coordination needs
`git status`/`diff`/`log` to assess a handoff, and the user asked for git read/write
including `push`, `reset --hard` and `clean` as standing capability. `git push/reset/clean`
are denied to every agent by the global destructive rule, so a role exception is needed.

## Decision Drivers

* Coordination needs first-hand repository state, not a second-hand report.
* The user (2026-11-20) granted standing authorization for `push`/`reset --hard`/`clean`.
* A general shell must stay unavailable: one `cp`/`sed -i`/`tee` bypasses the Write/Edit gate.
* Executor boundaries for `vorenus`/`pullo`/`posca` must not widen.

## Considered Options

* **General shell for anthory.** Rejected: destroys the Write/Edit self-protection (ADR 0006).
* **Reuse `executor`.** Rejected: the global destructive rule still denies push, and it
  would conflate coordination with implementation.
* **New `orchestrator` flag, executor allowlist + git write set.** Chosen.

## Decision Outcome

* New contract flag `orchestrator`, selected in `hooks/restrict-bash-by-agent.sh`.
* `exec_orchestrator_cmd_allowed` routes `git` to `exec_is_git_write` and everything else
  to the unchanged `exec_cmd_allowed`.
* The destructive rule in `hooks/lib/security.sh` is bypassed only for
  `agent_flag=orchestrator` + `argv[0]=git`; classification is then per-subcommand.
* Still denied: `git config`, `--git-dir`/`--work-tree`/`-C`/`-c`, `--exec`,
  `--upload-pack`/`--receive-pack`, filter/difftool/mergetool/bisect subcommands, and
  `push` with bare `--force`/`-f`/`--mirror`/`--delete`/`+refspec`.
* Write/Edit self-protection is unchanged: the orchestrator cannot write `hooks/`,
  `tests/`, `scripts/`, root `*.md`, `settings*.json`, `rules/` or `.git`.

## Consequences

* Accepted risk: `push` publishes to a remote; `reset --hard`/`clean -f` destroy working
  tree content. Mitigation: pre-commit hooks, `--force-with-lease`, and an audit-log line
  per decision. The user holds standing approval and may revoke it in one line.
* Residual: running `git commit` executes repository hooks (`.git/hooks`, or `core.hooksPath`
  if set) — repository code execution at hook privilege. Same accepted residual as ADR 0006.
* `-c`/`-C` remain denied fleet-wide, so `git switch -c` is refused; use `git checkout -b`
  or `git branch`.
* ADR 0006's role table is historical; this ADR supersedes it for `anthory` only.

## Links

* Partially supersedes: [0006](0006-7-role-bash-authorization.md)
* Still in force: [0003](0003-enforcement-boundary-and-accepted-residual-risk.md)
* Implementation: `hooks/lib/executor.sh`, `hooks/restrict-bash-by-agent.sh`
