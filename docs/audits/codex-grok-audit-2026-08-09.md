---
auditors: [Codex (gpt-5.2-codex), Grok (grok-4)]
date: 2026-08-09
target: /Users/suimumacmini/.claude/agents/
lenses: [官方 Claude Code subagent best practices, 奥卡姆剃刀（结构性简约）]
cross_validates: grill-report-2026-08-07.md (F1–F33)
---

# Codex + Grok 双模型审计报告 — `~/.claude/agents/`

> 审计标尺：官方 Claude Code subagent 文档 (`code.claude.com/docs/en/sub-agents`) + 奥卡姆剃刀
> 交叉验证：2026-08-07 grill 安全深度审计 F1–F33
> 审计员：Codex (gpt-5.2-codex, read-only sandbox) · Grok (grok-4, read-only)
> 日期：2026-08-09

---

## 0. 共识结论（双模型一致判定）

**这套 agent 语料的文本契约与仓库内单测完备，但「能力层强制」在 live 环境未接线——多个安全修复只存在于仓库文本中，运行时不生效。叠加 10 处引用的合约文件不存在、仲裁规则被抽成空壳，舰队处于「文档全绿、运行时半生效」状态。**

**整体判定（双模型共识）：PARTIAL CONFORMANCE / 存在配置漂移 / 不应将 guardrails 全绿视为真实安全保证。**

---

## 1. 🔴 CRITICAL — 双模型一致发现

### C1 — 能力层 hooks 未注册到 live `settings.json`

**Codex 证据：** `~/.claude/settings.json` PreToolUse（`:119-180`）和 PostToolUse（`:63-106`）均无 `restrict-write.sh`、`copy-on-write.sh`、`restrict-bash-by-agent.sh` 条目。permissions 仍为 `bypassPermissions`（`:261-265`）。

**Grok 确认：** hooks 单测 22 PASS，但 live settings 不加载。`_xixi.md:37` 指向 `~/.claude/hooks/xixi/CONTRACT.md`，实际在 `~/.claude/agents/hooks/xixi/CONTRACT.md`（路径漂移）。

**影响：**
- `_xixi` 的 Write 沙箱（F3 修复）**运行时不生效**——`bypassPermissions` 下可写任意路径
- mutator 的 Bash allowlist（F9 修复）**运行时不拦截**
- `bypassPermissions` + 无 hook = 所有 prompt-only 安全边界都是建议而非强制

**这意味着 grill 的 F3/F9/F13/F26/F28 在运行时层面均未真正修复。**

### C2 — `agent-output-contract.md` 悬空引用 ×10

**双模型一致：** 全部 10 个 agent 引用 `~/.claude/rules/agent-output-contract.md`（如 `architect.md:238`、`code-reviewer.md:112`、`security-reviewer.md:225`），但该文件**不存在**。Grill 将 F14/F16 标为 ✅ 完成（`grill-report-2026-08-07.md:427-428`）。

---

## 2. 🟠 HIGH — 双模型一致发现

### H1 — `rules/agents.md` 仲裁/互斥规则为空壳

Grill 声称 F6（触发仲裁）、F11（mutator 互斥）、F25（handoff 邻接表）已修复（`:419`、`:424`、`:431`）。实际 `~/.claude/rules/agents.md` 仅 15 行简单用途表，无仲裁条件、无写者互斥、无邻接边。各 agent 的 "Defer to pipeline" 指向不存在的 pipeline。

**双模型判定：进度虚报（"进度注水"）。**

### H2 — Mutator 缺「内容即数据」注入前导语

Grill F1 只给 4 个 reviewer + `_xixi` 补了注入前导语。5 个 mutator（build/tdd/refactor/doc/e2e）读取的源码、package scripts、测试名、注释同样是不可信数据，且权限比 reviewer 更高（Write/Bash），却无防护。

### H3 — 路径双真相源

文档（`_xixi.md:37`、`build-error-resolver.md:36`）写 `~/.claude/hooks/`，代码实际在 `~/.claude/agents/hooks/`。`CONTRACT.md` 声明 settings.json 是 live source，但 settings 不含对应条目。

### H4 — Prompt 与自动加载规则实质冲突

- `rules/testing.md:3` 规定 coverage threshold 由项目配置决定；`tdd-guide.md:260-275` 硬编码 ≥80%
- `rules/coding-style.md:5` 说行数只是 review signal 非阻断；`code-reviewer.md:80-88` 把 >50/>800 列为 HIGH
- `e2e-runner.md:160-165` 禁止固定 timeout；`tdd-guide.md:155-173` 的 E2E 示例用 `waitForTimeout(600)`

由于 subagent 自动加载这些规则，重复文本不是无害冗余，而是冲突指令。

---

## 3. ⚔️ 关键分歧 — 需用户裁决

### D1 — 舰队规模：10 → 4（Codex 激进）vs 保持 10 修接线（Grok 保守）

| | Codex 立场 | Grok 立场 |
|---|---|---|
| **核心主张** | 10 → 4：保留 architect、code-reviewer、security-reviewer、e2e-runner。删 planner/build/tdd/refactor/doc/_xixi（改为 skill 或主会话行为） | 10 个在职责上各自成立；问题在重复内容与未接线基础设施，不在 agent 个数 |
| **planner** | **删** — 与 architect 重叠，实现规划更适合主会话/Plan Mode | **保留** — 分阶段计划有独立价值；改 description 仲裁即可 |
| **build-error-resolver** | **删** — 快速迭代修复属主会话范畴 | **保留** — 窄职责"修绿构建"成立 |
| **tdd-guide** | **删** — TDD 是工作方式不是角色；`testing.md` 已有纪律 | **保留** — RED-GREEN-REFACTOR 流程独立 |
| **refactor-cleaner** | **删 mutator**，改 read-only dead-code auditor | **保留** — 删除门 + knip 是独立风险域 |
| **doc-updater** | **删** — 文档同步是当前任务最后一步，需主会话上下文 | **保留**（偏肥） — 专职合理，PR 模板/日程可砍 |
| **_xixi** | **删 agent**，改普通 prompt-refinement skill（剪贴板 side effect 复杂度 >> 价值） | **保留** — 剪贴板交付 + Write 沙箱是全队唯一特殊管线 |

### D2 — Model 策略

| | Codex | Grok |
|---|---|---|
| **推荐** | 全部 `model: inherit`（或省略），仅 e2e-runner 可固定 sonnet | 混合：review-only 硬编码 opus（architect/security），mutator 用 `inherit` 或统一 sonnet |
| **理由** | 官方默认就是 inherit；无 benchmark 证明 review 必须 opus | 纯 inherit 在主会话切 haiku 时会降低 review 质量；硬编码在成本敏感时更可预测 |

---

## 4. 新发现汇总（grill 安全审计未覆盖）

| ID | 来源 | 严重度 | 发现 |
|----|------|--------|------|
| N1 | Codex+Grok | **CRITICAL** | 能力层 hooks live 未注册（C1） |
| N2 | Codex+Grok | **HIGH** | `agent-output-contract.md` 悬空（C2） |
| N3 | Codex+Grok | **HIGH** | `rules/agents.md` 仲裁/互斥空壳（H1） |
| N4 | Codex+Grok | **HIGH** | Mutator 缺注入前导语（H2） |
| N5 | Codex+Grok | **MEDIUM** | 路径双真相源（H3） |
| N6 | Codex+Grok | **MEDIUM** | Prompt 与 rules 实质冲突（H4） |
| N7 | Codex | **MEDIUM** | 仓库合约把官方可选字段（tools/model）强制为必填——违背官方 schema |
| N8 | Codex | **MEDIUM** | "PROACTIVELY everywhere" 违反官方派发边界——简单任务也付子会话启动成本 |
| N9 | Codex+Grok | **MEDIUM** | code-reviewer 仍扛完整 Security Checks，与 security-reviewer 重叠 |
| N10 | Grok | **MEDIUM** | tdd-guide 内嵌 Playwright E2E 示例，与 e2e-runner 重叠 |
| N11 | Codex+Grok | **LOW** | guardrails 把 CLAUDE.md 当 agent → CI 假红 |
| N12 | Codex | **LOW** | `_xixi` `color: magenta` 非官方支持值 |
| N13 | Codex | **LOW** | refactor-cleaner prompt 自相矛盾：前禁 `git revert`，后指示立即 `git revert HEAD`（`:89-93` vs `:299-309`） |
| N14 | Grok | **LOW** | `_xixi` 标题 `## Security` 不符合约 `## Untrusted content` 字面 |

---

## 5. Grill F1–F33 交叉验证汇总

| 状态 | 数量 | Finding IDs |
|------|------|-------------|
| ✅ 真正生效 | 14 | F2, F7, F8, F17, F18, F19, F20, F21, F23, F24, F27, F31, F32, F33(text) |
| ⚠️ 文本生效但运行时未接线 | 6 | F3, F9, F13, F26, F28, F29 |
| ❌ 进度虚报/回退 | 5 | F6, F11, F14, F16, F25 |
| ⚠️ 外部待验证 | 1 | F4 (key rotation) |
| 部分生效 | 7 | F1(仅reviewer), F5(无行为测试), F10(e2e过度修复), F12(hook未验证token), F15(doc仍TS-bias), F22(security仍肥), F33(不消费内容) |

**关键结论：33 项中仅 14 项（42%）真正生效。**

---

## 6. 优先级行动建议

### P0 — 立即（接线 > 文案）

1. **注册 hooks 到 live settings.json**（或确认是否有其他加载层）——这是 C1，影响 F3/F9/F13/F26/F28 全部
2. **统一路径**：symlink `~/.claude/hooks/xixi` → `agents/hooks/xixi`，或改全部 prompt 指针
3. **创建或删除 `agent-output-contract.md`**——禁止继续悬空引用（C2）
4. **处理 `bypassPermissions` + 未注册 hook 的组合**——当前等于无安全边界

### P1 — 本周（真简约 + 真仲裁）

5. **重写 `rules/agents.md`**：写出 planner↔architect 仲裁条件、写者互斥、邻接 handoff 表（兑现 F6/F11/F25）
6. **mutator 加注入前导语**（或共享 include）
7. **修 guardrails**：排除 `CLAUDE.md`/`grill-*` 等 non-agent md；把 tools/model 检查改为"存在时校验合法性"而非"必须存在"
8. **裁决 D1（舰队规模）和 D2（model 策略）**

### P2 — 简约化

9. **DRY**：F19/F20/F23/Handoff 进单一规则，agent 留指针
10. **裁剪教材段**：architect 模式百科、security OWASP 教材、code-reviewer 安全程序——模型已知这些
11. **消除规则冲突**：以 `rules/testing.md` 和 `coding-style.md` 为唯一政策源
12. **删 `_xixi` `color: magenta`**（无效字段）

### P3 — 修复测试

13. Guardrails 按官方 schema 校验
14. trigger fixtures 真正运行或删除"single source"说法
15. 加行为测试：应触发 / 不应触发 / 重叠仲裁

---

## 附录 A — 当前资产快照

| 文件 | tools | model | 行数 |
|------|-------|-------|------|
| architect | Read, Grep, Glob | opus | 277 |
| planner | Read, Grep, Glob | opus | 156 |
| code-reviewer | Read, Grep, Glob | opus | 175 |
| security-reviewer | Read, Grep, Glob | opus | 348 |
| build-error-resolver | Read, Write, Edit, Bash | sonnet | 207 |
| tdd-guide | Read, Write, Edit, Bash, Grep | sonnet | 346 |
| refactor-cleaner | Read, Write, Bash, Grep | sonnet | 357 |
| doc-updater | Read, Write, Edit, Bash, Grep, Glob | sonnet | 320 |
| e2e-runner | Read, Write, Edit, Bash, Grep, Glob | sonnet | 229 |
| _xixi | Read, Grep, Glob, Write | sonnet | 164 |

## 附录 B — 审计标尺来源

官方 Claude Code subagent 文档 (`code.claude.com/docs/en/sub-agents`) 关键原则：
- "Design focused subagents: each subagent should excel at one specific task"
- "Write detailed descriptions: Claude uses the description to decide when to delegate"
- "Limit tool access: grant only necessary permissions for security and focus"
- 仅 `name` + `description` 必填；`tools`/`model` 可选
- `model` 默认 `inherit`；官方示例 code-reviewer 用 `model: inherit`
- Use main conversation when: frequent back-and-forth, shared context, quick targeted change
- Use subagents when: verbose output, enforce tool restrictions, self-contained work

