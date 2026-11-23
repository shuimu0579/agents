---
status: accepted
date: 2026-11-24
supersedes: 0008 (posca route), 0015 (anthory route), 0016 (route table only)
---

# Model fallback chains for posca and anthory

## Context and Problem Statement

The user changed two default external models (2026-11-24):

| Role | Primary | Fallback(s) |
|---|---|---|
| posca | `gemini-4-carbon-high` | `gemini-pro-orchestrator-neon` |
| anthory | `claude-opus-5-5-high` | `gemini-pro-orchestrator`, then `gemini-pro-orchestrator-neon` |

Two of the requested IDs do not exist in `agy models` (1.5.15). There is no
`gemini-pro-orchestrator-opus`; the user chose `claude-opus-5-5-high` instead, which
agy does list. `gemini-pro-orchestrator-carbon` is spelled `gemini-pro-orchestrator`
in agy (its display name is "Orchestrator (Carbon)"). The Carbon ID is used as the
agnostic name; the model list is the source of truth.

`agy` has no model-fallback flag: `--model` takes one value and a failed model ends
the turn. `tools/agent-cli.sh` already owned the role → CLI → model table, so the
chain had to be implemented there.

## Decision Drivers

* The user asked for a primary model and explicit fallbacks for both roles.
* The wrapper is the only admitted route to agy (ADR 0008); adding a second shape
  for retries would widen the gate.
* A failed attempt must not contribute partial output to the report the role relays.
* Falling back must not spend another model's quota after an interrupt.

## Considered Options

* **Ask each agent to retry the wrapper with another role or model.** Rejected:
  the wrapper pins the model per role and refuses options, and a cross-role call is
  denied with `rule:allowlist`.
* **Let the agents call `agy --model <fallback>` directly.** Rejected: raw agy is
  an arbitrary-execution grant with no fixed flags or hash pin (ADR 0008).
* **Carry the chain in the existing route string and retry inside the wrapper.**
  Chosen.

## Decision Outcome

* `exec_agent_cli_route` format is now `<cli>|<model>[|<fallback model>...]`.
  Single-model routes are unchanged:
  `mark`, `vorenus`, `pullo` (`agy`), `octavion` (`codex`), `atia` (`grok`).
  Multi-model routes:
  * `posca` → `agy|gemini-4-carbon-high|gemini-pro-orchestrator-neon`
  * `anthory` → `agy|claude-opus-5-5-high|gemini-pro-orchestrator|gemini-pro-orchestrator-neon`
* The PreToolUse gate still only checks that the role maps; it does not inspect the
  chain. `exec_is_agent_cli` is unchanged.
* `tools/agent-cli.sh` keeps the original `exec` path for a single-model route
  (no buffering, no temp file). For a chain it runs each model in order, capturing
  the attempt's stdout under a `mktemp -d` directory:
  * the first exit 0 prints that attempt's stdout and exits 0;
  * a signal exit (`>= 128`) prints the attempt's stdout and exits with that code
    instead of spending another model's quota;
  * a failed non-final attempt's stdout is discarded; a one-line diagnostic naming
    the model and exit code goes to stderr;
  * if every model fails, the last attempt's stdout is printed and the last exit
    code is returned.
* Binary resolution and the SHA-256 pin are still checked once, before the chain
  starts; the chain never changes `cli`, `cli_bin`, flags or prompt channel.
* `posca.md` and `anthory.md` document the primary and fallbacks; `anthory.md`'s
  dispatch table names posca's new primary and anthory's chain.
* `tests/hooks.test.sh` asserts the new primary in the dispatched argv and adds a
  fallback case: a shim fails the primary, and the test asserts the second model
  ran and the failed attempt's stdout is absent from the result.

## Consequences

* A dead or exhausted primary now costs one extra turn of latency and one attempt
  of the primary's quota before the fallback runs. The wrapper cannot distinguish
  auth, quota and transient errors; any non-zero, non-signal exit falls through.
* `claude-opus-5-5-high` is a Claude model reached through the agy backend. ADR
  0017's accepted residual (the external turn runs outside the Claude hooks with
  full host access) is unchanged; the model's vendor does not alter the boundary.
* The prompt is still passed as `--print=<prompt>` for agy, so it remains visible
  in same-user process listings (ADR 0008, audit B12). A chain runs that exposure
  once per attempt.
* Historical route tables in ADR 0008 and ADR 0015 remain as written; this ADR
  supersedes the posca and anthory rows and ADR 0016's route list only.

## Links

* Partially supersedes: [0008](0008-default-external-cli-routes.md),
  [0015](0015-anthory-default-orchestrator-neon-route.md),
  [0016](0016-external-cli-first-for-all-roles.md)
* Still in force: [0007](0007-orchestrator-standing-git-authority.md),
  [0017](0017-external-cli-full-host-access.md),
  [0003](0003-enforcement-boundary-and-accepted-residual-risk.md)
* Implementation: `hooks/lib/executor.sh`, `tools/agent-cli.sh`, `posca.md`,
  `anthory.md`, `tests/hooks.test.sh`
