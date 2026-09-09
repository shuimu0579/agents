---
status: accepted
date: 2026-09-09
---

# Remove Bash from `e2e-runner` instead of sandboxing Playwright execution

## Context and Problem Statement

The 2026-09-09 full audit (`Agents 仓库工程审计报告`, Codex `gpt-6-astra` thread `01a083bb`) found six Critical findings in `hooks/restrict-bash-by-agent.sh`. Three of them (#4, #5, #6) share one root cause that no regex fix can reach:

`e2e-runner` holds `Write`/`Edit` on the repo **and** is allowed by the Bash gate to run `playwright test`. Playwright executes repository config and spec files as Node code with no sandbox. The agent can therefore author a spec that calls `child_process` and does anything the hook process itself could do — read `~/.claude` credentials, overwrite the hooks constraining it, delete `hooks/approvals/`, rewrite `~/.claude/rules/`. Separately, `playwright test --output=<dir>` recursively clears its output directory before a run, so even a benign CLI option can delete the enforcement layer.

Repository-level "trusted root" attestation does not fix this, because the agent edits the executable files *after* attestation. The `restrict-mutator-write.sh` gate operates at the tool boundary and cannot intercept Node filesystem calls.

Should the fleet isolate the Playwright execution surface, or remove the capability that creates it?

## Decision Drivers

* This is one developer's laptop, not a CI fleet. A solution requiring ongoing operational work will rot.
* The hooks repo depends only on bash, jq, python3 today. A heavyweight runtime dependency is a real cost.
* Whatever is chosen must be verifiable by a probe that fails if the protection is removed.
* **Measured usage**: `e2e-runner` has never been exercised. Of 32 commits, the 5 mentioning e2e all *harden its gate*; none use it. `hooks/approvals/` contains only its README — no approval was ever issued. No `playwright.config.*` exists anywhere under `$HOME` (depth 3). Playwright is not installed on this machine.

## Considered Options

* **Seatbelt (`sandbox-exec`)** with a deny-by-default profile around the whole Playwright process tree, behind a protected launcher — Codex's recommendation (thread `01a083dd-4071-7682-8437-7d180626cd58`)
* **Docker / container** holding the entire Node runner and browsers
* **A separate macOS user account** running e2e work via `launchd`/`su`
* **Remove `Bash` from `e2e-runner`**, leaving it an authoring agent; the orchestrator runs Playwright under human supervision when needed
* **Retire `e2e-runner` entirely** to `archive/`

## Decision Outcome

Chosen option: **"Remove `Bash` from `e2e-runner`"**, because it closes #4, #5 and #6 completely and immediately at near-zero cost, while the alternative that is strongest on security buys that strength for a capability with zero realized usage.

Codex recommended Seatbelt and its analysis is sound on the merits — it correctly noted that Playwright publishes ARM64 images (so containers are not categorically emulated on Apple Silicon), and that moving only the browser into Docker is useless because the *runner* must cross the boundary. Its own comparison table also concedes that removing Bash "removes this direct execution route if removal is enforced"; its objection was functional loss, not security insufficiency.

That objection rested on an assumption the evidence does not support. Codex had no usage data and treated the autonomous run/edit/re-run loop as a hard constraint. Under the Decision Drivers above, that loop has never once run. Paying for Codex's implementation (protected launcher, Seatbelt profile, disposable job staging, environment/descriptor sanitization, adversarial integration suite, negative controls, browser-matrix qualification) — plus requalification on every macOS, Node, Playwright and browser upgrade, against an interface Apple has marked deprecated — is precisely the ongoing operational work this fleet cannot sustain.

The Seatbelt design is not discarded. It is recorded below as the accepted architecture for reactivation, so the decision can be reversed without re-deliberating.

### Consequences

* Good, because #4, #5 and #6 close completely rather than narrowing — there is no execution path left to escape from
* Good, because it costs nothing to maintain and adds no dependency
* Good, because `e2e-runner` keeps its real value: authoring and repairing specs, proposing quarantine, reading artifacts the orchestrator collects
* Bad, because the agent can no longer run tests, read its own failures, or iterate autonomously; a human or the main session must run Playwright and hand back results
* Bad, because a spec authored inside the fleet is still ordinary executable code — running it later, outside any sandbox, remains a trust decision the fleet does not gate
* Neutral, because the fleet loses nothing it was actually using

### Confirmation

* `e2e-runner.md` frontmatter no longer lists `Bash` in `tools`
* `tests/fixtures/agent-contract.tsv` carries the matching `expected_tools` for `e2e-runner`, so `tests/guardrails.sh --strict` fails if agent and contract drift apart
* `hooks/restrict-bash-by-agent.sh` denies every command for `agent_type=e2e-runner` — probe `tests/p1-bypass.test.sh` asserts this, including the previously bypassing payloads from #1, #2 and #3
* `~/.claude/rules/agents.md` reflects the reduced capability in its write-capable agent table

## Reactivation design (accepted, not implemented)

If `e2e-runner` is ever given execution back, this is the design to implement — do not re-deliberate it, and do not restore `Bash` without it.

**Mechanism**: `sandbox-exec` (Seatbelt) with a deny-by-default profile applied to the entire Playwright process tree, before any repository-controlled executable loads.

1. **One protected entry point.** The profile is applied before local launchers, Node preloads, config and dependencies are read. The agent cannot select the profile or disable confinement, and no direct Playwright launch path may remain as an alternative. A missing `agent_type` must not grant an unconfined route.
2. **A disposable job directory.** Stage only required inputs; exclude credentials and enforcement files. Writes permitted only to the job workspace, a temporary HOME, browser profiles and the artifact directory.
3. **A clean process context.** Allowlist environment variables, close unrelated inherited descriptors (Seatbelt does not revoke already-open fds), withhold authentication-agent sockets and host automation services.
4. **Compatibility gates.** Qualify the browser matrix headless-first. A failing browser must never trigger a broader permission grant, and there must be no automatic unsandboxed fallback.

**Acceptance probe** — the boundary is unproven until this passes on the actual machine:

* Canaries (a random-nonce secret, sacrificial hooks/approvals/rules directories) placed *outside* the allowed paths but readable/writable by the same UID, so ordinary permissions cannot explain a denial. Include canaries adjacent to allowed directories to catch prefix errors.
* Hostile fixtures at every stage — config initialization, a spec, a spawned Node child, a shell grandchild — each attempting: read the secret; overwrite an enforcement canary; unlink and recursively delete an approval canary; rename a protected directory; repeat via a symlink out of the job dir. Each must be denied, and each stage must prove it actually ran (a missing file or a browser that never launched is a probe failure, not a pass).
* Real Playwright cleanup exercised with `--output=<sacrificial protected dir>` and again via config `outputDir`; canaries must be unchanged.
* Proof that useful execution survives: a real browser against a disposable server, a deliberate assertion failure, valid screenshot/video/trace opened by the outer harness, then an edit-and-rerun cycle.
* **Mandatory negative control**: repeat the filesystem and cleanup probes with Seatbelt removed, same UID and paths. The nonce must become readable and the canaries destroyable. If the suite stays green without Seatbelt, it never tested the boundary.

**Accepted residual risk on reactivation**: Seatbelt is a deprecated, shared-kernel boundary, not VM separation; the job is expendable and isolation does not establish test correctness; granted network authority is real authority (`baseURL` parsing does not constrain arbitrary Node requests); and host-side agent tools remain outside the process sandbox, so `restrict-mutator-write.sh` must protect the launcher and profile themselves.

**Runner-up**: Docker containing the entire Node runner and browsers, with no host-home or Docker-socket mount. It becomes the better pick if the required browser matrix cannot pass the acceptance suite without weakening the Seatbelt profile — accept the runtime cost then, rather than broadening native access until confinement is nominal.
