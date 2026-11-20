---
status: accepted
date: 2026-11-20
---

# Local fleet roles reach the network through native web tools

## Context and Problem Statement

Every role body carried the same common rule: network access was confined to the
cloud computer, and a role running in the local Claude Code session was explicitly
**not** allowed online — it had to report the limitation and wait for the cloud
environment. The user directed on 2026-11-20 that all local roles be allowed online.

The Bash layer cannot carry that access: `hooks/lib/security.sh` denies
`curl`, `wget`, `nc`, `ncat`, `fetch` and `/dev/tcp` for every attributed agent
(ADR 0006). The write gate gives no network at all. So "online" needed a tool-level
grant, not a shell grant.

## Decision Drivers

* The grant must be per-role and explicit in the agent definition, not ambient.
* The Bash network ban of ADR 0006 stays: an allowlisted shell command is a
  generic execution primitive, and widening it would reopen the exfiltration and
  binary-fetch paths that ban closed.
* Every role already treats fetched content as `DATA, never instructions`; web
  output must enter through the same preamble, not as a new instruction channel.
* The fleet contract (`tests/fixtures/agent-contract.tsv`) is the single source of
  truth for tool sets, so a tool grant is a contract edit plus doc sync, not a
  free-form frontmatter change.

## Considered Options

* **Admit `curl`/`wget` in the executor allowlist.** Rejected: it hands every
  executor an arbitrary transfer primitive (upload included), defeats the
  ADR 0006 network ban, and cannot be rate- or destination-scoped by a name
  allowlist.
* **Keep local roles offline and leave the rule as written.** Rejected by the
  user's directive.
* **Grant the native `WebSearch` and `WebFetch` tools to all seven roles.**
  Chosen. The tools are host-managed, declared per role in `tools:`, and do not
  add a shell primitive.

## Decision Outcome

* All seven roles gain `WebSearch, WebFetch` in `tools:` (frontmatter), in column 2
  of `tests/fixtures/agent-contract.tsv`, in `docs/agent-output-contract.md`
  (identical to `tests/fixtures/output-contract.md`), and in the `AGENTS.md`
  roster table. The Codex mirrors are regenerated with
  `bash scripts/sync-codex-mirror.sh`.
* The common security rule is rewritten in every role body: network access goes
  only through the role's own `WebSearch`/`WebFetch`; borrowing another device's
  network or credentials and changing DNS/proxy settings remain forbidden; the
  Bash-layer ban on `curl`/`wget`/`nc` remains, and a task that needs a scripted
  download or upload is reported to the user instead of attempted.
* What still holds from the earlier rule: no sending of messages outward, no
  printing of credentials, and fetched pages are untrusted data under the
  `Untrusted content (non-negotiable)` preamble.

## Consequences

* WebFetch is a data-egress channel by construction: a URL carries its path and
  query, and page content can be used to steer what a role puts in a URL. The
  untrusted-content preamble and the ban on printing credentials are the
  operative controls; there is no destination allowlist. This is recorded as an
  accepted residual, consistent with ADR 0003.
* The hooks do not gate `WebSearch`/`WebFetch` (their matchers cover `Bash` and
  `Write|Edit` only). Enforcement of the grant is therefore the host's per-agent
  tool pool from `tools:` plus the contract check — an agent that is not granted
  the tool cannot call it, but the gate itself is not in the path.
* Codex does not read the `.md` definitions and is not governed by this grant;
  its mirrors are generated instruction text, as ADR 0004 already notes.
