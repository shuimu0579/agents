---
auditors: [Codex (gpt-5.6-sol, read-only), Claude (Fable 5, independent pass)]
date: 2026-08-09
target: /Users/suimumacmini/.claude/agents/
baseline: codex-grok-audit-2026-08-09.md (N1–N14, C1–C2, H1–H4) + grill-report-2026-08-07.md (F1–F33)
lenses: [官方 Claude Code sub-agents best practices, 奥卡姆剃刀（结构性简约）]
execution: 双模型独立 pass → 交叉验证（本报告）；分歧项交由用户裁决
---

# Codex + Claude 验证审计 — `~/.claude/agents/`（闭环第二轮）

> 目的（用户 Q1=B）：以上轮审计为基线，**逐项验证整改在运行时是否真正生效**，只补真实缺口。
> 深度（用户 Q6=A）：P0+P1（接线 + 门禁 + 一致性）。P2 简约化 / P3 测试 / 全局 settings 改动排除。
> 方法（用户 Q3=B）：Codex（gpt-5.6-sol, read-only runner）+ Claude 独立复核，交叉验证。

---

## 0. 共识结论（双模型一致）

**上轮「文档全绿、运行时半生效」的判词被证实在两个新维度上成立，且严重程度高于上轮评估：**

1. **🔴 CRITICAL — `archive/` 不是归档边界。** Claude Code 递归扫描 `~/.claude/agents/`，`archive/*.md`（6 个已「退役」agent）仍是可加载的 runtime agent。本次会话的可用 agent 列表即包含全部 6 个。**10→4 精简在运行时从未生效——当前仍是 10-agent 舰队，而编排规则按 4 个假设运转。**
2. **🔴 CRITICAL — 全局 `settings.json` 存明文凭据**（`settings.json:74`，`ANTHROPIC_AUTH_TOKEN`）。**用户已裁决（Q9）：保留，是 CC Switch 切换模型的凭据，不进本轮。** 记录在案，不做动作。
3. **🟠 HIGH — guardrails 红（12 FAIL）**，根因是 CONTRACT 表仍列 10 个 agent。
4. **🟠 HIGH — 输出契约存在多套互斥真相**：不只「10 vs 4 舰队」规模冲突，还有 token 拼写（`APPROVE WITH CHANGES` vs `APPROVE_WITH_CHANGES`）、映射分歧（architect `BLOCKED`→`BLOCK` vs `NEEDS_INPUT`）、agent prompt 与 rules 的 token 族不匹配（security 的 SAFE-family vs prompt 的 APPROVE-family；e2e 的 PASSING-family vs prompt 的 GO-family）、以及「Verdict 必须末行」契约 vs 模板把 Verdict 放头部。

**整体判定：PARTIAL CONFORMANCE 依旧成立，且修复未接线问题（NF1/NF3/NF4）是真正的闭环动作。** 上轮 42% 生效率的结论被再次证实。

---

## 1. 上轮发现交叉验证（Codex ⊕ Claude）

| ID | 上轮判定 | 本轮状态 | 双模型证据 |
|----|---------|---------|-----------|
| C1 | 🔴 hooks 未接线 | **STILL_OPEN** | 双模型一致：无 fleet hook 注册于 live settings；`bypassPermissions` 仍在。处置见 NF5/Q7 |
| C2 | 🔴 contract 悬空 | **STILL_OPEN** | 双模型一致：文件已存在（不再悬空），但仍是 10-agent 表，与 4-agent 舰队冲突（NF4） |
| H1 | 🟠 仲裁空壳 | **RESOLVED** | 一致：`rules/agents.md` 已有触发仲裁、并发/互斥、handoff 图 |
| H2 | 🟠 mutator 无前导语 | **RESOLVED** | 一致：唯一 mutator（e2e-runner）已含注入前导语；archive 内 mutator 亦含（NF1 修复后不再相关） |
| H3 | 🟠 路径双真相 | **RESOLVED** | 一致：active 引用统一为 `~/.claude/agents/hooks/`；xixi 路径在退役后无关 |
| H4 | 🟠 prompt/rules 冲突 | **RESOLVED** | 一致：coverage 归项目配置、行数为 review signal、固定 timeout 示例已删 |
| N1 | CRITICAL hooks | STILL_OPEN | = C1（处置见 Q7 删除决策 + NF5 运行时缺口） |
| N2 | HIGH contract | STILL_OPEN | = C2 |
| N3 | HIGH 仲裁 | RESOLVED | = H1 |
| N4 | HIGH 注入前导语 | RESOLVED | = H2 |
| N5 | MEDIUM 路径 | RESOLVED | = H3 |
| N6 | MEDIUM 冲突 | RESOLVED | = H4 |
| N7 | MEDIUM 官方 schema | **STILL_OPEN**（Codex） | guardrails 已按官方 schema 放行（tools/model 可选），但 **`agents/CLAUDE.md:47` 文档仍把 tools 标为 required**——文档未随代码同步 |
| N8 | MEDIUM PROACTIVELY 过泛 | **STILL_OPEN**（Codex） | `rules/agents.md:3,39` 仍要求全量主动派发 + 每次变更必审，与官方「快速定向改动用主会话」冲突。**政策裁决项** |
| N9 | MEDIUM 安全检查重叠 | **STILL_OPEN** | 双模型一致：code-reviewer.md:68 仍扛完整 Security Checks，与 security-reviewer 重叠 |
| N10 | MEDIUM tdd E2E 重叠 | **STILL_OPEN**（Codex） | tdd-guide 内嵌 Playwright E2E 且仍在 runtime 可发现（NF1）→ 由 NF1 修复顺带解决 |
| N11 | LOW guardrails 假红 | **RESOLVED** | 一致：guardrails 已排除 CLAUDE.md/grill-*/codex-* |
| N12 | LOW color 值 | RESOLVED | 一致 |
| N13 | LOW revert 矛盾 | RESOLVED | 一致 |
| N14 | LOW 标题字面 | RESOLVED | 一致 |

**共识：16 项中 9 项真正解决；7 项仍开（C1/C2/N1/N2/N7/N8/N9/N10）。**

---

## 2. 新发现（双模型交叉后确认）

### NF1 — 🔴 CRITICAL：`archive/` 不构成停用边界
六个 `archive/*.md` 均含有效 `name`/`description` frontmatter，Claude Code 递归扫描即加载。**运行时是 10-agent 舰队**，编排规则却按 4 个运转：重叠触发（planner↔architect）、mutator 暴露（5 个写者仍在）、N10 重叠全部复活。
**修复**：`archive/*.md` → `*.md.disabled`（或移出 `~/.claude/agents/`）；guardrails 增加「archive/ 下不得有 `.md`」的失败断言。

### NF2 — 🔴 CRITICAL：`settings.json:74` 明文凭据
`ANTHROPIC_AUTH_TOKEN`（`bypassPermissions` 同文件 `:306`）。**用户裁决保留（CC Switch 用途，Q9）**，本报告仅记录，不做动作。安全团队若引入则需 rotate 指引。

### NF3 — 🟠 HIGH：guardrails CONTRACT 表 10 行 vs 发现深度 1 层
`guardrails.sh:93` 10 行 CONTRACT + `:226` 仅 `-maxdepth 1` 发现 → 既因 6 个 root 文件移走而 FAIL，又看不见这 6 个在 archive/ 下仍可加载。实测：**12 FAIL / 7 WARN / exit 1**（非 strict 与 strict 同）。
**修复**：CONTRACT 收敛为 4 个 active；删除已归档 worker 的 model WARN 段；发现逻辑与 runtime 发现对齐。

### NF4 — 🟠 HIGH：输出契约多套互斥真相
| 维度 | `agent-output-contract.md` | `rules/agents.md` | agent prompt |
|------|---------------------------|-------------------|--------------|
| 舰队规模 | 10（含 6 个 archived） | 4 | 4 |
| architect `BLOCKED` | → `BLOCK` | → `NEEDS_INPUT` | → `BLOCK`（architect.md:274） |
| code-reviewer token | `APPROVE WITH CHANGES` | `APPROVE_WITH_CHANGES` | `APPROVE WITH CHANGES` |
| security token 族 | SAFE-family | SAFE-family | **APPROVE-family**（security-reviewer.md:229） |
| e2e token 族 | PASSING-family | PASSING-family | **GO-family**（e2e-runner.md:190） |
| handoff | 10-agent 链 | 4-agent 链 | 指向 rules/agents.md |
| mutator 互斥 | 5 写者（`_xixi` 误标并行安全） | 唯一写者 e2e-runner | — |
| Verdict 位置 | 必须「末行」 | — | 模板全部放**头部**（4 个 agent） |

**修复**：`agent-output-contract.md` 收敛为 4-agent 唯一真相（舰队、token 表、handoff、互斥、Verdict 位置约定）；`rules/agents.md` 删除重复映射改为引用；4 个 agent prompt 的 token 与契约归一；guardrails 校验「Verdict 末行」而非仅 token 存在。

### NF5 — 🟠 HIGH：prompt 声称的能力层强制运行时不存在
`e2e-runner.md:40` 声称 PreToolUse hook 拦截特权命令（approvals 一票制），但 `restrict-write.sh` / `copy-on-write.sh` / `restrict-bash-by-agent.sh` **均未注册进任何 settings**。`bypassPermissions` 下 e2e-runner 的 Bash/Write 限制纯 prompt-only。
奥卡姆评估：`xixi/*` 在 `_xixi` 真正退役后即死代码；`restrict-bash-by-agent.sh` 唯一活消费者是 e2e-runner，但 4/5 分支指向已退役 agent。
**处置（Q7=A 已裁决）**：删除 `xixi/` 全量 + `restrict-bash-by-agent.sh`（未接线的死代码）；保留 `approvals/`。**运行时强制缺口（e2e Bash 白名单 + approvals 门）作为后续决策项**：需在全局 settings.json 接线（本轮 settings 只读，超出范围）。

### NF6 — 🟠 MEDIUM：e2e-runner 自我矛盾
description 承诺「生成 E2E 测试」（e2e-runner.md:4），preflight 却在「无既有 journeys」时 STOP（:99）——包括用户**显式要求创建首个 journey** 的场景。
**修复**：:99 改为「无 journeys 且 scope 未指明」才 STOP；显式首次创建请求放行。

### NF7 — 🟠 LOW：rules 存在 enforced-vs-default 漂移（P2，记录）
`testing.md`/`security.md`/`performance.md` 大量复述内置行为；verdict 策略在两份互斥 rules 重复。总预算 179 行达标。按用户 Q6=A 排除，仅记录。

---

## 3. 四个 active agent 定义审计（双模型一致）

| Agent | 结论 |
|-------|------|
| architect（276 行） | 触发可判、read-only 工具对；**handoff 仍指向已退役 planner**（:271）；正文被架构教材主导（P2） |
| code-reviewer（176 行） | 触发/最小权限/inherit 良好；**重复 security-reviewer 完整安全检查**（N9）；token 拼写与 agents.md 不一致 |
| security-reviewer（347 行） | 触发/read-only 强；**prompt 过大**（P2）；**APPROVE-family 与两份 rules 的 SAFE-family 冲突** |
| e2e-runner（233 行） | 工具集/sonnet/injection 前导语对；**当前接线下不安全**（NF5）、**首个 journey 矛盾**（NF6）、**第三套 verdict 词汇** |

---

## 4. 建议整改清单（P0/P1，逐项待用户确认后执行）

### P0 — 接线 / 门禁
1. **停用 archive/ 6 个 agent**：`archive/*.md` → `*.md.disabled`；guardrails 加「archive/ 下无 `.md`」断言（修复 NF1）
2. **guardrails 收敛**：CONTRACT 表 → 4 个 active；删已归档 model WARN 段；审 `triggers.yml` 与 runtime 舰队对齐（修复 NF3）→ `bash tests/guardrails.sh` exit 0
3. **输出契约单源化**：`agent-output-contract.md` → 4-agent 唯一真相；`rules/agents.md` 删重复映射改引用；4 个 agent prompt 的 domain token 与契约归一（修复 NF4，兑现 Q8=A）
4. **删除孤儿 hooks（Q7=A）**：`hooks/xixi/*`（restrict-write / copy-on-write / common / CONTRACT）+ `hooks/restrict-bash-by-agent.sh`；保留 `approvals/`

### P1 — 一致性
5. **architect.md:271** handoff → 4-agent 图（去掉 planner）
6. **N8 政策裁决**：`rules/agents.md:39` 「每次变更必审」→ 限定为实质性 merge-bound 变更（或维持严格，待你定）
7. **N9**：code-reviewer.md:68 安全检查收敛为通用正确性 + secret 初步分诊，auth/injection/SSRF/crypto 路由 security-reviewer
8. **NF6**：e2e-runner.md:99 允许显式首个 journey 创建
9. **N7**：`agents/CLAUDE.md:47` 文档 → 仅 name+description 必填，tools/model 可选但需显式声明

### 决策项（不自动执行，需要你拍板）
- **D-A**：e2e-runner 的 Bash/approvals **运行时强制**——本轮只删死代码（Q7=A），运行时缺口留后续接线（全局 settings.json，本轮只读），还是你有其他安排？
- **D-B**：NF2 凭据——维持 Q9 保留不变，仅记录。
- **D-C**：N8 严格审 vs 放宽。

### 明确排除（记录不动作）
- NF2 凭据（Q9）、`bypassPermissions`（全局）、NF7 规则漂移（P2）、教材裁剪（P2）、行为测试（P3）、根 `~/CLAUDE.md` 的 hooks.json 说法漂移（仓库外）。

---

---

## 5. 终态（平行审计收敛后 · 2026-08-09）

本报告撰写后，仓库被一次**平行 Codex 审计 + 修复**（`codex-audit-2026-08-09.md`，cc-suite audit-agent，gpt-5.6-sol）与本次整改共同推进。收敛后的终态：

### 已落地（本次 + 平行修复合计）
- **NF1**：`archive/*.md` → `*.md.disabled` — 6 个退役 agent 不再被运行时递归加载；guardrails 增加「archive/ 无 `.md`」断言
- **NF3**：guardrails CONTRACT 收敛为 4 个 active → **0 FAIL / 3 WARN（plain）/ exit 0**（3 WARN 为按官方 schema 省略 model 字段的设计提示）
- **NF4**：`agent-output-contract.md` → 4-agent 唯一真相；`rules/agents.md` 去重映射改引用；域 token 归一为 **architect RECOMMEND 系 / code-reviewer APPROVE 系 / security-reviewer SAFE 系 / e2e-runner PASSING 系**；**Verdict 统一为报告末行**
- **NF5/Q7**：孤儿 hooks（`hooks/xixi/*`、`restrict-bash-by-agent.sh`）删除，保留 `approvals/`；运行时接线留待裁决（D-A）
- **architect 死 handoff**：planner 引用已移除（平行修复）
- **N9**：code-reviewer 安全检查收敛为「升级不重复」，OWASP 全量归 security-reviewer（平行修复；参考文件 `docs/agents/security-checklists.md`）
- **NF6/P1-8**：e2e-runner preflight 允许显式首个 journey bootstrap（平行修复）
- **N7**：`agents/CLAUDE.md` frontmatter 文档 → 仅 name+description 必填
- **model 政策**：reviewers `inherit`（字段省略）、e2e-runner `sonnet` — 已同步进 guardrails 检查与 rules；**D2（architect=opus）未裁决**
- 触发夹具 `triggers.yml`、CI `agents-ci.yml` 同步为 4-agent

### 仍开放（决策项）
| 项 | 状态 |
|---|---|
| **D-A 运行时 Bash/approvals 接线** | 未接线（settings.json 无 fleet hook）；`e2e-runner.md:159` 仍引用已删除的 hook — 该文件由平行进程持有，未改 |
| **D2 architect model** | `opus` 候选未应用；guardrails/rules 按 inherit 收尾，一行可改 |
| **NF2 凭据** | 用户裁决保留（CC Switch，Q9） |
| **bypassPermissions** | 全局默认模式；未改动（超范围，仅记录） |
| **P2 简约化 / P3 行为测试** | 排除本轮 |

---

**Verdict:** NEEDS_INPUT — 闭环（guardrails 绿、4-agent 运行时生效、契约单源）已完成；剩余为 D-A 运行时接线与 D2 model 两项待裁决决策。
