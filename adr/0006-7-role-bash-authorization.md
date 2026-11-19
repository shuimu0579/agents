---
status: accepted
date: 2026-11-19
supersedes: 0002 (executor roles only)
---

# Execution-only Bash authorization for the 7-role fleet's executor roles

## Context and Problem Statement

The fleet was replaced by seven roles on 2026-11-19:

| Role | Contract flag | Responsibility |
|------|---------------|----------------|
| `anthory` | `review_only` | coordination and summary |
| `mark` | `review_only` | intent check |
| `octavion` | `review_only` | research and plan |
| `posca` | `executor` | independent review and ledger |
| `atia` | `review_only` | process spot check |
| `vorenus` | `executor` | primary implementation |
| `pullo` | `executor` | fallback implementation |

`vorenus`, `pullo` and `posca` must both **write** and **run** (tests, git status,
`git diff` for review). ADR 0002 removed `Bash` from the only writing agent in the
legacy fleet because "write code + execute it" is arbitrary code execution at hook
privilege. That reasoning has not changed; what changed is that the new team cannot
function without execution.

The 2026-09-09 audit (finding #5) reached the same conclusion: with a general shell,
`cp`, `sed -i`, `tee` or `git checkout` bypass the Write/Edit self-protection in one
command, so a lexical deny list over a general shell is not a boundary.

The contract already carried a `mutator` flag that grants Bash whenever the tools
column declares it. That is enough for the legacy parser but says nothing about
*which* commands an executor may run.

## Decision Drivers

* Executor roles must run the repository's own acceptance suites.
* Write/Edit self-protection must remain absolute for fleet assets.
* A general shell with a deny list cannot preserve that property (D1).
* The gate is an authorization boundary, not a sandbox (ADR 0003).
* The fleet contract is the single source of truth for tool sets (D3).

## Considered Options

* **General shell + deny list.** Rejected: one `cp`/`sed -i`/`tee`/`git checkout`
  bypasses the Write/Edit gate; `bash script.sh` and `npm test` are arbitrary code
  execution regardless of lexical checks.
* **Execution-only allowlist per executor.** Chosen.
* **OS sandbox / container / separate user.** Out of scope for this port; remains a
  separate project.

## Decision Outcome

Chosen option: **execution-only allowlist**, implemented in
`hooks/lib/executor.sh` and selected by contract flag `executor`.

* `review_only` roles declare no `Bash` and the gate denies them with
  `rule:review-only`.
* `executor` roles declare `Bash`; the gate applies the global deny rules first, then
  the allowlist. Anything not explicitly allowed is denied with `rule:allowlist`.
* The contract flag list is now `review_only | mutator | executor`. `mutator` retains
  the legacy parser path; the live fleet uses only `review_only` and `executor`.

### Allowed families

* Read: `ls`, `cat`, `head`, `tail`, `wc`, `grep`, `rg`, `stat`, `file`, `pwd`,
  `which`, and `command -v`.
* Git read-only: `status`, `diff`, `log`, `show`, `rev-parse`. Every argv token is
  scanned; any of the following is refused because it changes git's configuration,
  execution path, repository root, output destination, or diff helper:
  `-c`, `--config-env`, `--exec-path`, `--git-dir`, `--work-tree`, `-C`,
  `--paginate`, `--output`, `--ext-diff`, `--textconv`, `--no-index`.
* Test runners: `pytest`, `python3 -m pytest`, `go test`, `cargo test`,
  `make <test|tests|check|lint|build>`,
  `npm|pnpm|yarn|bun test`, `npm|pnpm|yarn|bun run <test|tests|lint|typecheck|check|build>`.
  `make` refuses `-f`/`--file`, `-C`/`--directory`, `--eval` and `-I`/`--include-dir`
  because each changes which makefile or code runs. `go test` refuses
  `-toolexec`, `-exec` and `-overlay` for the same reason.
* Python: `python3 -m unittest` (`-v`, `discover`, `-s`, `-p`, `-t` plus one value,
  and a dotted test name), and `python3 -m json.tool` (at most one file). Any other
  `-m <module>` is refused.
* Fleet test scripts: `bash|sh <path>` where the canonical (symlink-resolved) path is
  under `${FLEET_ROOT}/tests`, ends in `.sh`, and is a regular file. `..` is refused
  before canonicalization. `scripts/` is refused as a whole directory:
  `scripts/create-approval.sh` can mint approvals (an approval bypass) and
  `scripts/sync-codex-mirror.sh` writes `~/.codex` (a write-gate bypass).

### Positional path rule is part of the authorization boundary

`pytest <path>`, `python3 -m unittest -s <path>` and `go test <pkg>` are equivalent to
executing that file or package. Therefore positional arguments for these runners must
be non-empty relative paths with no `..` segment; absolute paths are refused. This is
not a style preference and must not be treated as a detail that a flag or an attached
option value can bypass.

### Explicitly denied

`cp`, `mv`, `sed`, `awk`, `tee`, `dd`, `truncate`, `install`, `ln`, `chmod`, `chown`,
archive extraction, `find`, `xargs`, `env`, `timeout`, `sudo`, `ssh`/`scp`/`rsync`,
`git add/commit/checkout/restore/apply/am/merge/rebase/cherry-pick/push/reset/clean`,
`bash -c`, `sh -c`, `python3 <file>`, `node <file>`, and any shell metacharacter
(`;`, `&&`, `|`, redirection) which the tokenizer already refuses.

## Consequences

* **Write/Edit self-protection is absolute.** A flagged agent cannot Write/Edit
  `hooks/`, `tests/`, `scripts/`, root `*.md`, `settings*.json`, `.git`, or `rules/`;
  approvals are denied to everyone.
* **Bash-layer self-protection is best-effort.** The allowlist blocks direct
  `cp`/`mv`/`sed -i`/`tee`/`git checkout`, but "write a script and run it", `npm test`
  and `pytest` can still execute project code that writes to disk. This is an
  **accepted residual**, not a sandbox. ADR 0003 continues to apply.
* **Compensation.** Every executor Bash decision is written to `HOOK_AUDIT_LOG`
  (who/when/rule, never the command body). Executors report changed paths, test
  commands and exit codes to `posca`, who checks `git status`/`git diff` for fleet
  assets.
* **Not a sandbox.** ADR 0003 (gate, not sandbox) and ADR 0005 (the gate governs this
  fleet, not every agent) remain in force. ADR 0002 is superseded only for the three
  executor roles; its decision still stands for any writing agent that is not an
  executor.
* **`adr/` is not in the write gate's protected set.** An executor can Write/Edit
  ADRs. This was left unchanged in this port; recording it here makes the residual
  visible. Moving `adr/` into `is_protected` is a separate hardening change.
* **Running the fleet suite itself edits live agent definitions.** `tests/p3-guardrails-quality.test.sh`
  temporarily rewrites `<agent>.md` files in the live tree to prove the contract gate
  detects damage; the EXIT trap restores them. If the suite is interrupted
  (Ctrl-C, SIGKILL, sleep), a live `.md` can be left modified — equivalent to bypassing
  the Write/Edit self-protection once. Recovery: `cp -a /tmp/fleet-baseline-<ts>/<agent>.md .`
  (or re-copy all seven), then run `bash tests/guardrails.sh --strict`. The test suite
  is not a passive observer of fleet assets.
* **Stale Codex mirrors.** `~/.codex/agents` still contains the six legacy TOMLs;
  `scripts/sync-codex-mirror.sh` regenerates named mirrors but does not delete
  orphans. Cleaning them requires explicit authorization.

## Links

* Superseded in part: [0002](0002-remove-bash-from-e2e-runner.md) (executor roles only)
* Still in force: [0003](0003-enforcement-boundary-and-accepted-residual-risk.md),
  [0005](0005-the-gate-governs-this-fleet-not-every-agent.md)
* Contract: `tests/fixtures/agent-contract.tsv`
* Implementation: `hooks/lib/executor.sh`, `hooks/restrict-bash-by-agent.sh`
