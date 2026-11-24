---
status: accepted
date: 2026-11-24
supersedes: 0017 (agy flag list only)
---

# Pin the Orchestrator effort block in the wrapper

## Context and Problem Statement

The user asked that `gemini-pro-orchestrator-neon` run at thinking effort
`xhigh` for every fleet agent. `agy` (1.5.16) rejects the obvious flag:

```
error: invalid model selection (--model "gemini-pro-orchestrator-neon" --effort "xhigh"):
       --effort is not supported for model "gemini-pro-orchestrator-neon"
```

For Orchestrator models, effort belongs to the `orchestrator` settings block —
the Planner and Executor each carry their own model-and-effort choice
(`/model` → Orchestrator row → Tab across Planner, Planner Effort, Executor,
Executor Effort). Those choices live in `~/.gemini/antigravity-cli/settings.json`
and can also be passed per session with `--settings`, whose argument is a JSON
object of `settings.json` keys.

Four routes dispatch the model: `vorenus` and `pullo` as primary, `posca` and
`anthory` as fallbacks. A user-local `/model` change would silently alter all of
them, and there was no way to see the intended effort from the repository.

## Decision Drivers

* The requirement is per model, not per role: every route dispatching the neon
  Orchestrator should get the same planner/executor effort.
* `tools/agent-cli.sh` owns the CLI, model and flags, and has two agy call paths
  (single-model `exec` and the fallback chain); they must not drift.
* The value must survive a later `/model` change on the host and be visible in
  review, like every other pinned flag.
* `--effort` is not an option (agy refuses it for these models), and there is no
  effort-suffixed neon Orchestrator ID in `agy models`.

## Considered Options

* **Leave effort to the user's global `settings.json`.** Rejected: invisible to
  the repository, and drifts whenever `/model` changes.
* **Switch the route to `gemini-4-neon-xhigh`.** Rejected: that is the plain
  Neon family, not the Orchestrator the user asked for.
* **Pin a `--settings` payload beside the route table, applied by the
  wrapper.** Chosen.

## Decision Outcome

* `hooks/lib/executor.sh` gains `exec_agent_cli_model_settings <model>`. For
  `gemini-pro-orchestrator-neon` it prints:

  ```json
  {"orchestrator":{"planner":"Gemini 4 Neon (XHigh)","executor":"Gemini 4 Hydrogen (XHigh)"}}
  ```

  and returns non-zero otherwise. The map is keyed by model, so every route —
  including fallback positions — inherits it, and a role later moved onto the
  model gets it without a route-table change.
* `tools/agent-cli.sh` sends both agy call paths through one `run_agy` helper:
  `agy --dangerously-skip-permissions --disable-slash-commands --model <model>
  [--settings <json>] --print=<prompt>`. Other agy models are unchanged, and
  codex/grok are untouched.
* `tests/hooks.test.sh` asserts the payload in the vorenus and pullo argv and in
  the neon attempt of the anthory fallback chain, and that no other attempt
  carries `--settings`.
* This partially supersedes ADR 0017's agy flag list; the host-access decision
  itself is unchanged.

## Consequences

* Fleet dispatches to the neon Orchestrator now override the host's `/model`
  planner/executor choice with the repository's. That is the intended
  determinism; changing the effort for the fleet is a route-table edit, not a
  local setting.
* The payload uses agy's **display names** (`Gemini 4 Neon (XHigh)`), because
  that is how the picker stores them. An agy upgrade that renames a display
  string would make the block stale; after upgrading, re-run one real dispatch
  through `tools/agent-cli.sh` and check that it still fails noisily rather than
  silently degrading. The argv tests pin the shape, not agy's acceptance.
* Verified end to end on 2026-11-24: with the payload set to Neon (XHigh) the
  wrapper's conversation metadata resolved the planner to `gemini-4-neon-xhigh`;
  temporarily changing the payload's planner to Carbon (High) resolved to
  `gemini-4-carbon-high`, proving `--settings` overrides the global block.
* Everything else from ADR 0008/0017 stands: binary resolution, SHA-256 pin,
  role binding, and full host access for the external turn.

## Links

* Partially supersedes: [0017](0017-full-host-access-for-external-cli-routes.md)
* Related: [0008](0008-default-external-cli-routes.md),
  [0018](0018-model-fallback-chains.md)
* Implementation: `hooks/lib/executor.sh`, `tools/agent-cli.sh`,
  `tests/hooks.test.sh`, `vorenus.md`, `pullo.md`, `posca.md`, `anthory.md`,
  `AGENTS.md`
