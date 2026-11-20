# Audit Findings

**Run**: audit-fix 20261120-104224 | **Scope**: F1 + C5 from the 2026-11-20 full-chain test | **Audit type**: targeted (no re-audit; file:line evidence from posca/atia/anthory)
**Model**: gpt-6.2-sol | **Effort**: high | **Audit thread**: n/a (findings produced by the fleet chain, verified by posca #2/#3 and atia)
**Status values**: open | fixed | not-fixed | partial | regressed | skipped (severity filter) | skipped (user stop) | deferred (ADR history)

| # | File | Line | Severity | Dimension | Finding | Suggested fix | Status | Round |
|---|------|------|----------|-----------|---------|---------------|--------|-------|
| 1 | tests/fixtures/output-contract.md | 74-76 | Medium | Correctness / Contract | pullo has no `NEEDS_INPUT` domain status. pullo's contract-mandated refusal when Vorenus quota evidence is missing is semantically "needs input", but the only expressible status is `BLOCKED`, which the table maps to `BLOCK` — so a correct reply is forced to contradict the table. | Add `\| pullo \| NEEDS_INPUT \| NEEDS_INPUT \|` immediately after the `pullo / BLOCKED` row. Keep this fixture authoritative. | fixed | 1 |
| 2 | docs/agent-output-contract.md | 74-76 | Medium | Correctness / Contract | Synced copy of the fixture above. `tests/guardrails.sh` requires this file to be byte-identical to `tests/fixtures/output-contract.md` (guardrails `:410-414`). | After fixing the fixture, copy it verbatim to this path (do not hand-edit differently). | fixed | 1 |
| 3 | pullo.md | 58 | Medium | Compliance | Delivery template declares `**Domain status:** PASS \| FAIL \| BLOCKED`, with no `NEEDS_INPUT`, so the new contract row has no matching output token in the role definition. | Change to `PASS \| FAIL \| BLOCKED \| NEEDS_INPUT`. Do not change any other pullo behavior. | fixed | 2 |
| 4 | tests/fixtures/agent-contract.tsv | 9 | Medium | Compliance | pullo row's domain-status column is `PASS;FAIL;BLOCKED`, out of sync with the fixed contract table and role template. Guardrails compares this column against agent bodies. | Append `;NEEDS_INPUT` to pullo's domain-status column. | fixed | 1 |
| 5 | AGENTS.md | 188-190 | Low | Documentation | Live contract says self-protection covers "root `*.md`", but `hooks/restrict-mutator-write.sh:424` uses `case "${fleet_root_cf}/"*.md`, and `*` matches `/` in shell `case`, so any `.md` at any depth under the fleet root is protected. Documentation understates the actual (stricter) behavior. | Reword to state that Write/Edit self-protection covers any `*.md` under the fleet root at any depth. Do NOT change the hook. | fixed | 1 |
| 6 | anthory.md | 41 | Low | Documentation | Same inaccurate claim in the orchestrator role definition ("根 `*.md`"). | Reword consistently with AGENTS.md. Preserve the rest of the line. | fixed | 1 |
| 7 | adr/0006-7-role-bash-authorization.md; adr/0007-...; adr/0010-... | 109 / 42 / 69 | Low | Documentation | These historical ADRs also say "root `*.md`". Repo rule: do not rewrite an ADR's decision outcome; supersede with a new ADR instead. | Do not edit these files in this run. Report the residual so SUIMU can decide whether to add a superseding ADR. | fixed | 3 (superseding ADR 0014) |
| 8 | chain-test/verdict_map.py | 8-38 | Low | Consistency | (Optional, test artifact) After finding 1 the contract has 23 mappings; this artifact's table had 22. | Add `("pullo", "NEEDS_INPUT"): "NEEDS_INPUT",` after the pullo BLOCKED entry. Existing 5 tests remain valid. | fixed | 1 |
| 9 | tests/hooks.test.sh | 909 | Low | Test quality | `grep -qF "$secret_probe"` where `secret_probe` starts with `--`; grep treats it as an option and exits 2, so the negated assertion passes even if stderr echoed the secret — a false green. Found during the fix run; outside the approved F1+C5 scope. | Use `grep -qF -- "$secret_probe"`. | fixed | 3 |

## Rules for this fix round

- Make minimal, targeted edits at the reported locations; no refactoring.
- Do NOT modify `hooks/restrict-mutator-write.sh` (C5 direction is documentation only), and do NOT modify ADRs.
- `docs/agent-output-contract.md` must stay byte-identical to `tests/fixtures/output-contract.md`.
- After edits, run and report: `bash tests/guardrails.sh --strict`, `bash tests/hooks.test.sh`, `bash scripts/sync-codex-mirror.sh`, `bash scripts/sync-codex-mirror.sh --check`, `bash tests/run_all.sh`, `bash tools/pin-clis.sh --check`.
- If a command fails for sandbox reasons (not a real test failure), report the exact error instead of working around it.
