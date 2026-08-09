---
plugin: grill
version: 1.2.3
date: 2026-08-09
target: /Users/suimumacmini/.claude/agents/
style: Select All (1-5 全风格) + Paranoid Mode
addons: Scale stress, Hidden costs, Principle violations, Strangler fig, Success metrics, Before vs after, Assumptions audit, Compact & optimize
agents: recon, architecture, error-handling, security, testing, edge-cases, codex（独立复核，已完成）
---

# Grill Roast — Claude Code Agent Fleet（Select All 复审）

> 目标：`/Users/suimumacmini/.claude/agents/` 的**修改内容**（未提交工作区 → 复审期间被并发会话收敛并提交为 `b895390`）。
> 范围：4 个 active agent + guardrails/hooks/tests/CI + `~/.claude/rules/` 契约 + `~/.claude/settings.json` 接线。
> **重大背景：复审期间目标在持续被另一个会话重写（14:21–15:01，7 个文件多次变更），最终收敛为 git clean + 双闸门全绿。所有发现均对照最终态核实。**

---

## 0. 执行摘要

**一句话判定**：舰队架构（4 角色分工、review-only vs 唯一 mutator、归档纪律、guardrails/CI 回归网）设计合理，且并发会话在复审期间已把**最危险的两个 CRITICAL（不可执行门禁、审批自铸）和大部分 HIGH 修掉并提交**；但**安全姿态仍有两个承重墙未经实证**——Bash 门禁依赖的 `agent_type` 字段没有真实 payload 验证（可能整体空转），以及 Playwright 执行的是仓库自身的可执行 JS（无沙箱）。当前状态：**BLOCK → 补两个实证测试后可转为 GO**。

**Top 3 行动**：
1. **实证 H4**：抓一份真实 PreToolUse payload，断言 `agent_type` 确实存在且 hook 能正确归因（否则整个 Bash 门禁是空转的，所有下游修复都建立在沙滩上）。
2. **堵生产保护 config 绕过**：`--config` 跳过校验、子串匹配、大写 scheme 三个洞（edge-cases 已实证 3 种绕过均 exit 0）。
3. **收窄 trust 豁免**：3 个 review agent 把仓库 `CLAUDE.md/AGENTS.md` 当"可信政策"——审恶意仓库时就是注入通道；应限定为"orchestrator 显式 attest 的可信仓库"。

**Confidence**：H4（agent_type 缺失）→ 中-高（edge-cases 翻过 2.1.226 二进制引用，hooks.test 全用合成 payload）；config 绕过 → 高（3 种已端到端实证）；trust 豁免 → 高（直接读 prompt 文本）。提升置信的关键动作就是 Top 3 的 1 和 2。

**Paranoid Verdict（最吓人的一件事）**：在最终态，**Bash 门禁对"唯一 mutator 的 Bash 调用"的约束，建立在一个从未被真实数据验证过的字段（`agent_type`）上**。若该字段在某版本 harness 中缺失/改名，门禁对 review-only agent 的拦截会全部退化为 no-jq 分支的 fail-closed（堵住，但同样拦了合法调用）——**不是泄一个洞，是整个安全层原地失效**。

---

## 1. Meta-finding：审计期间目标移动 + 并发收敛

- **实测**：`hooks/restrict-bash-by-agent.sh` 复审期间改 3 次（174→225→240 行）、guardrails/hooks.test/4 个 agent/CI 各改 1–2 次；mtimes 跨 14:21–15:01。
- **过程风险（CRITICAL，已缓解）**：期间多个瞬间"闸门 vs 闸门测试"互相矛盾（多行注入在 14:52 仍可打穿、`npx` 白名单反转 CI 红）。最终由并发会话原子提交 `b895390`，git 工作区已 clean。
- **残余建议**：未来提交应**原子化**（hook 与其测试同批）；CI 加"测试时 `git status --porcelain` 非空即 FAIL"步骤，杜绝审脏树。

## 2. 最终态验证（FIXED vs OPEN）

| 项 | 状态 | 证据 |
|---|---|---|
| 钩子可执行位 0644→0755 | ✅ FIXED | `-rwxr-xr-x`；CI 有 `test -x`；hooks.test 49 通过含 "settings.json registers restrict-bash hook" |
| 审批 token 自铸 | ✅ FIXED | 新增 Write\|Edit PreToolUse 钩子拦 `/hooks/approvals/` 写入（exit 2 "orchestrator-only"） |
| 多行命令注入 | ✅ FIXED | raw-command 前置检查（hook 归一化前） |
| `npm test`/`npm run *` 任意脚本 | ✅ FIXED | 白名单只剩本地 playwright / `npx --no-install` / git/ls/which/command -v |
| 裸 `npx` 自动安装 | ✅ FIXED | `npx --no-install` 才放行 |
| no-jq fail-open | ✅ FIXED | no-jq 现在直接 BLOCK（"cannot attribute agent_type, Install jq"） |
| token 族冲突（agent vs 契约） | ✅ FIXED | 契约冻结为 agent 口径：security=APPROVE 族、e2e=PASSING 族；guardrails 查 "Verdict after Handoff" |
| Verdict 位置（末行契约） | ✅ FIXED | guardrails 4b2 检查 + 4 个 agent 模板已重排 |
| 归档 `archive/*.md.disabled` + NF1 | ✅ FIXED | guardrails 断言 archive/ 无 `.md` |
| mutator 注入前导语 guardrails | ✅ FIXED | 4c 检查已含 `review_only\|mutator` |
| **`agent_type` 归因实证** | 🔴 **OPEN** | hooks.test 全用合成 payload（`:40`），无真实抓包 |
| **生产保护 config 绕过** | 🔴 **PARTIAL** | `--config` 仍跳过校验（hook:212）、子串/大写 scheme 未证已修 |
| **trust 豁免（注入重开）** | 🔴 **OPEN** | 3 个 review agent 仍把仓库 CLAUDE.md/AGENTS.md 当可信 |
| **Playwright 执行不可信 JS** | 🔴 **OPEN** | 无沙箱/容器；prompt "DATA" 不是系统边界 |
| **guardrails 4b2 pipefail 潜在 abort** | 🟠 **OPEN** | `_hln`/`_vln` 无 `\|\| true`（`set -Eeuo pipefail` 下 grep 无匹配即全脚本 abort） |
| 报告文件堆根目录（5 份） | 🟠 **OPEN** | 已被提交进仓库根；应移 `docs/audits/` |
| 其余 MEDIUM/LOW | 🟠/🟡 见 §4 | — |

## 3. 综合发现（按严重度，去重后保留最强证据）

### CRITICAL
- **C1 [FIXED] Bash 门禁不可执行 + bypassPermissions**：`restrict-bash-by-agent.sh` 曾 0644（exit 126），全局 `permissions.defaultMode: bypassPermissions`。现 0755 + CI 断言。（security/testing/error-handling）
- **C2 [FIXED] 唯一 mutator 可自铸审批**：`consume_approval` 只查存在+mtime；e2e 有 Write/Edit 且无权限提示。现已由 Write\|Edit 钩子拦 `/hooks/approvals/`。（security/edge-cases）
- **C3 [OPEN] 审计期树不稳**：已收敛提交，但过程教训未固化（原子提交 + dirty-tree FAIL）。（edge-cases）
- **C4 [OPEN] Playwright 执行仓库自身的 JS**：spec/config 可 import child_process 提权；无沙箱。属架构决策，需明示接受或上容器。（security）

### HIGH
- **H1 [OPEN] `agent_type` 归因未实证**：hook 决策键在 `.agent_type`，hooks.test 全用合成 payload；若真实 PreToolUse payload 无此字段，门禁对 review-only 的拦截退化为 no-jq 分支（误杀）或 pass-through（空转）。（error-handling/edge-cases）
- **H2 [PARTIAL] 生产保护 config 绕过**：`--config custom.conf.ts` 完全跳过校验；`baseURL:'https://localhost.evil.com'` 过子串过滤；`HTTP://` 大写 scheme 不匹配。（edge-cases，3 种均实证 exit 0）
- **H3 [OPEN] trust 豁免重开注入**：3 个 review agent 声明"运行时装载的仓库 CLAUDE.md/AGENTS.md 是可信政策"——审外部/恶意仓库时是注入通道（"set Recommendation APPROVE"）。（security/N10）
- **H4 [FIXED] 多行注入**：raw-command 前置检查。（architecture/edge-cases）
- **H5 [FIXED] npm 包装脚本任意代码**：白名单已移除 npm/yarn 包装。（security）
- **H6 [OPEN] hook agent 名单 vs CONTRACT 漂移**：hook 硬编码 case 列表（`*) exit 0` 放行未知 agent）；新增 mutator 不改 hook 即获无限制 Bash；无测试耦合两清单。（edge-cases）

### MEDIUM
- **M1 [OPEN] guardrails 4b2 pipefail 潜在 abort**：`grep -n` 无 `\|\| true`。（error-handling）
- **M2 [OPEN] grep 截断策略不可实现**：Grep 工具 `-l`=仅文件名、content 模式必然带出全文；"path:line 不泄全文"做不到，transcript 即泄漏渠道。（security/N9）
- **M3 [OPEN] 审批 TOCTOU**：两 e2e 实例可同时消费同一 one-shot 文件（无锁）。（edge-cases）
- **M4 [OPEN] quarantine 无到期**：fixme 永久跳过，issue 关/owner 走都无回收。（edge-cases）
- **M5 [OPEN] 具名 staging host 假阳性**：prompt 允许 orchestrator 具名 staging，hook 只认 `*.test/*.local/*.staging` 后缀 → 合法审批被拦。（edge-cases）
- **M6 [OPEN] `tools:` YAML block 跳过工具契约**：`get_field` 只读 `^tools:` 行。（edge-cases）
- **M7 [OPEN] token 检查是字面子串**：无法区分"文档提及"与"真实 domain status"。（edge-cases/testing）
- **M8 [OPEN] 根目录 5 份报告可被 runtime 扫描**：guardrail 仅按 `codex-*`/`grill-*` 前缀排除。（architecture/edge-cases/R6）
- **M9 [OPEN] CI 非 strict**：D2 模型策略/行数是 WARN-only，CI 永不 fail。（testing）
- **M10 [OPEN] 契约文件在仓库外**：CI 只 checkout agents 仓库，验不到真实 settings.json 注册与契约映射。（testing）
- **M11 [OPEN] 无审计日志**：hook 决策不落日志，排障靠 transcript 反推。（error-handling）

### LOW（分组按文件，待触碰时一并处理）
- architect.md：不校验 repo root 存在；prompt 重复段（Role 列表/反模式清单/末行复述）。
- code-reviewer.md：与 security-reviewer 共享 APPROVE 族造成"哪个 reviewer 批的"歧义；嵌入 finding 示例冗余。
- security-reviewer.md：责任清单与 workflow/reference 重复；末行通用 exhortation。
- e2e-runner.md：`Recommendation` 与 `Domain status` 双字段同 token 可误判；命令 cookbook 与 workflow 重复；虚构 journey 示例。
- guardrails.sh：总结行硬编码 "(4 agent files)"；CONTRACT 表缺 model/domain-token 列；skip-list 按前缀耦合。
- restrict-bash-by-agent.sh：`date +%s` 失败 fail-open；`rm -r -f` 变体过破坏性正则；approval 文件 mode 不查（README 声称 600）；mtime 恰好 300s 边界；`--base-url` word-splitting；config 检查限 cwd。

## 4. 各 Agent 判定

| Agent | 判定 | 一句话 |
|---|---|---|
| architect | ✅ 健康 | 触发可判、review-only、handoff 正确；LOW：root 校验 + 文本冗余 |
| code-reviewer | ✅ 健康 | 已把系统性 OWASP 交给 security-reviewer；LOW：token 语义歧义 |
| security-reviewer | 🟠 可用 | 硬 no-shell、证据敏感、UNKNOWN 态正确；但 trust 豁免 + grep 截断不可实现 |
| e2e-runner | 🟠 风险最大 | 工具集正确、生产意识强；但 `agent_type` 归因 + Playwright 无沙箱 + 审批机制仍靠归属信任 |

## 5. 压力测试（Select All 全 8 项）

- **Scale stress**（100x 仓库/团队翻倍）：最先破的是 H6（新 agent 不加 hook 即得无限制 Bash）与 M3（并行 e2e 审批竞态）；团队翻倍时 guardrails CONTRACT 与 hook 双清单手工同步必漂。
- **Hidden costs**：排障 hook 决策无日志；理解 240 行 hook+guardrails+契约的三层心智负担；契约文件在仓库外导致的 CI 假绿排查成本；并发写同一批文件的协调成本（本次实测）。
- **Principle violations**：SRP（hook 兼任 gate+approvals+prod-guard 三职责）；DIP（agent 清单在 guardrails 与 hook 双写，无单一抽象）；最小权限（e2e 对整个树 Write/Edit，虽已补 approvals 拦截但仍宽）。
- **Strangler fig**：不重写。按序：(a) 单源化 agent 清单（hook 读 CONTRACT）→ (b) 契约 vendor 进仓库供 CI → (c) 报告移 docs/audits/ → (d) H4 真实 payload 测试。无 big-bang。
- **Success metrics**：guardrails/hooks.test 通过率（现 0/0、49/0）；CI 假绿率→0（加映射/注册断言）；契约漂移检出时间（目标 <1 次提交）；dirty-tree 提交数→0。
- **Before vs after**：10-agent/3 mutator/未接线 hooks → 4-agent/1 mutator/接线但 H4 未实证的 gate。
- **Assumptions audit**（显式列出待验证）：① `agent_type` 在真实 payload 存在（**最关键，未验证**）；② orchestrator 不会审恶意仓库（**假**，security-reviewer 的职责正是审它）；③ Playwright config/spec 安全可执行（**假**）；④ 同时只有一个 e2e-runner（advisory 非强制）；⑤ jq 存在（已 fail-closed 兜底）。
- **Compact & optimize**：4 个 prompt 各有可删文本（architect Role 清单/末行、code-reviewer 嵌入示例、security 责任清单重复、e2e 命令 cookbook+虚构 journey），合计约 60–80 行可移 docs 或删，不损失行为。

## 6. Edge Case Risk Matrix（Paranoid Mode）

| # | 场景 | 可能性 | 影响 | 风险 | 状态 | 文件 |
|---|---|---|---|---|---|---|
| 1 | e2e 自铸审批（声称的拦截不存在） | 高 | 高 | CRITICAL | ✅ 已修（Write\|Edit 拦 approvals/） | hook |
| 2 | 审脏树提交（gate 与 gate-test 互相矛盾） | 高 | 高 | CRITICAL | ✅ 已收敛；建议 dirty-tree FAIL | 全仓 |
| 3 | 生产保护被 config 绕过（--config/子串/大写） | 中 | 高 | HIGH | 🔴 部分开 | hook:195-218 |
| 4 | `agent_type` 真实 payload 缺失→门禁空转 | 中 | 高 | HIGH | 🔴 开 | hook:30-31 |
| 5 | hook agent 清单 vs CONTRACT 漂移→新 agent 无限制 Bash | 中 | 高 | HIGH | 🔴 开 | hook:66-76 |
| 6 | "Verdict after Handoff" 检查误杀自然布局（已搞挂过全部 4 agent） | 中 | 中 | MEDIUM | ✅ 已收敛；仍脆 | guardrails:184-191 |
| 7 | 具名 staging 被 hook 假阳性拦截 | 中 | 中 | MEDIUM | 🔴 开 | hook:150-156 |
| 8 | quarantine fixme 到期无回收 | 中 | 中 | MEDIUM | 🔴 开 | e2e-runner.md:171 |
| 9 | 审批 TOCTOU（双实例消费同一 one-shot） | 低 | 中 | MEDIUM | 🔴 开 | hook:117-134 |
| 10 | 根目录报告 .md 可被 runtime 扫描 | 中 | 中 | MEDIUM | 🔴 开 | guardrails:209-220 |

## 6.5 Codex 独立复核补录（复审完成后返回）

> Codex 对照最终提交 `b895390`（HEAD）复核；guardrails/hooks.test 因沙箱限制未完整执行，静态 `bash -n` + 有限非写入探针通过。

### 对已知项的状态（Codex 独立判定）
| 项 | Codex 判定 | 说明 |
|---|---|---|
| R4 token 族 | ✅ 已修 | 全部 family 对齐（reviewer=APPROVE*、architect=RECOMMEND/OPTIONS/BLOCKED、e2e=PASSING/QUARANTINE/FAILING） |
| R5/N1 hook | ✅ 已修 | 0755 + CI 断言可执行/直调 + settings 注册 |
| N2 审批自铸 | ◐ PARTIAL | Write/Edit 已拦；但 agent 仍可借可编辑的 Playwright JS 自铸 token / 启动特权子进程（hook 看不到） |
| N3 生产保护 | ◐ PARTIAL | 显式 URL + 字面 config URL 已查；动态/imported config 与一切 `--config` 仍绕过 |
| N4 Playwright JS | 🔴 CONFIRMED | 无沙箱执行仍成立 |
| N5 白名单 | ✅ 已修 | 本地 playwright / node_modules/.bin / npx --no-install 对齐；清理项：e2e-runner.md:40 裸 npx 示例改 `--no-install` |
| N6 guardrails | ◐ PARTIAL | pin/trigger/位置已查；domain 仍为字面 token 存在性、"after Handoff"≠"末行" |
| N7 code-reviewer | 🔴 CONFIRMED | `:71` 说 escalate 仍带 `:75-82` 八项安全检查清单 |
| N8 severity 契约 | 🔴 CONFIRMED | 契约无 severity 定义，security-reviewer 私有一份 |
| N9 grep 截断 | 🔴 CONFIRMED | 不可实现 |
| N10 trust 豁免 | 🔴 CONFIRMED | 仍在 3 个 review agent |
| N11 prompt 冗余 | 🔴 CONFIRMED | 精确行号，可删约 140–180 行 |

### 新发现（N12–N19）
- **N13 [HIGH] 审批分支绕过命令白名单**：特权检查按 `playwright …` 任意位置匹配，并在精确 launcher allowlist 之前 `allowed=1` → 持有 token 时 `python3 /tmp/x.py playwright test --update-snapshots` 可达任意 Python 执行（仅 `python -e` 被拒）。**本轮最重要的新发现。** 修复：先校验精确 launcher + 完整命令形态，再消费 token。
- **N12 [MEDIUM] BLOCK 与 NEEDS_INPUT 语义重叠**：契约把"缺输入"归 BLOCK 又定义 NEEDS_INPUT；architect 把缺前置映射到 NEEDS_INPUT → 路由不确定。修复：BLOCK 只表"已确立的失败/风险"。
- **N14 [MEDIUM] CI 运行时接线检查静默 SKIP**：CI 只给 HOOK_SRC，测试在无 `~/.claude/settings.json` 时 SKIP → 干净 runner 验不到注册。修复：tracked 脱敏 settings fixture。
- **N15 [MEDIUM] E2E 目标解析不可执行**：prompt 要求读 `$BASE_URL`/具名 staging，hook 拒 `$` 展开、禁 env/printenv、只认固定后缀 → 自相矛盾。修复：dispatcher 提供已解析目标 + 结构化 allowed-host。
- **N16 [MEDIUM] OWASP Top 10 引用过时**：security-checklists 用 2017 版（XXE/反序列化置顶、漏 SSRF），与声称的系统 SSRF 覆盖矛盾。修复：标注并更新到具体现行版本。
- **N17 [MEDIUM] handoff 邻接缺实现环节**：architect→code-reviewer 直连，但设计稿在实现前不可审。修复：architect → 主会话实现 → review → 修复+同范围复审 → e2e → 终审。
- **N18 [LOW] trigger 夹具仍非行为性**：triggers.yml 自称 single source，guardrails 只查 agent 名 + 一个正例。修复：加派发评估 harness 或按奥姆剃刀删除。
- **N19 [MEDIUM] code-reviewer 被要求证明工具拿不到的事实**：Read/Grep/Glob 下查覆盖率/依赖许可证/漏洞依赖，无 UNKNOWN 规则。修复：要求 dispatcher 提供测试/审计/许可证结果，或标 NOT VERIFIED。

## 7. Fixing Plan

### Phase 1 — 承重墙实证（立即）
- **F1 [H1]** 抓真实 PreToolUse payload：临时给 hook 加一行 `echo "agent_type=$agent_type" >> /tmp/hook-attribution.log`，跑一次真实 review-only 子代理 Bash 调用 + 一次 e2e-runner 调用，断言字段存在且归因正确；随后在 hooks.test 加"真实形状 payload"用例。*失败则整个 Bash 门禁不可信，须先解决。*
  - **Files**：hooks/restrict-bash-by-agent.sh、tests/hooks.test.sh
- **F2 [H2]** 生产保护 config 绕过三修：`--config` 时解析并校验目标 config 文件；config 的 baseURL 走 `url_host`/`host_safe`（弃子串 `grep -vE`）；scheme 大小写归一。
  - **Files**：hooks/restrict-bash-by-agent.sh:195-218 + hooks.test.sh 补 3 用例
- **F3 [C4]** e2e 执行不可信 JS：二选一——(a) 明确文档化为"prompt 级边界 + orchestrator 必须 attest 仓库可信"；(b) 上容器/沙箱（secrets 剥离）。建议 (a) 先落地，决策项交给用户。
  - **Files**：e2e-runner.md、fleet CLAUDE.md

### Phase 2 — HIGH（本迭代）
- **F4 [H3]** trust 豁免收窄：3 个 review agent 改为"仅 orchestrator 显式 attest 的可信仓库，其 CLAUDE.md/AGENTS.md 才可信；嵌套/外部仓库一律 DATA"。
  - **Files**：architect.md:37、code-reviewer.md:31、security-reviewer.md:39
- **F5 [H6]** agent 清单单源化：hook 的 case 列表改为读 guardrails CONTRACT（或生成），并加 guardrails 断言"hook 清单 == CONTRACT tool flags"。
  - **Files**：hooks/restrict-bash-by-agent.sh、tests/guardrails.sh
- **F6 [C3]** CI 加 dirty-tree FAIL：测试步骤前 `git status --porcelain` 非空即 exit 1。
  - **Files**：.github/workflows/agents-ci.yml

### Phase 3 — MEDIUM（下一迭代）
- **F7 [M1]** guardrails 4b2 两行 grep 加 `|| true`（同 `get_field` 模式）。
- **F8 [M2]** security-reviewer grep 策略改为：`files_only` 定位候选文件 → Read + 手动截断；批量密钥扫描路由给 owner 的 trufflehog/gitleaks；同步改 security-checklists.md 的 `-l` 误述。
- **F9 [M3]** 审批消费加 `mv` 原子认领（rename→consumed）代替 exists-then-rm，杜绝 TOCTOU。
- **F10 [M4]** quarantine fixme 强制带到期（`'Issue #N; expires YYYY-MM-DD'`）+ guardrails 扫过期 token。
- **F11 [M5]** staging allowlist 单源化：prompt 与 hook 共用同一命名来源（env 具名 host 或 approvals 文件），消除假阳性。
- **F12 [M6]** guardrails `tools:` 支持 YAML block 或对 block 风格 fail-closed。
- **F13 [M7]** guardrails 解析 `**Domain status:**` 行做精确 token 匹配，弃整文件子串。
- **F14 [M8]** 根目录 5 份报告移 `docs/audits/`（含本报告）；guardrails 改为"非 CLAUDE.md 根 .md 一律必须在 CONTRACT，否则 FAIL"。
- **F15 [M9]** CI 改 `--strict`（或把 D2 模型策略从 warn 升 fail）。
- **F16 [M10]** 契约 vendor 进仓库（tests/fixtures/output-contract.md）+ 同步 diff 检查；settings.json 注册 grep（有则断言）。
- **F17 [M11]** hook 每次调用落一行审计日志（agent_type/rule/时间戳）。

### Phase 4 — LOW（触碰该文件时）
- architect.md：加 repo root 校验；删 Role 列表/反模式清单冗余。
- code-reviewer.md：评估 security 是否该用 SAFE 族消除"哪个 reviewer 批的"歧义（契约/guardrails 同步改）；删嵌入示例冗余。
- security-reviewer.md：删责任清单与 reference 重复。
- e2e-runner.md：合并 `Domain status`/`Recommendation` 双字段；删虚构 journey 示例。
- guardrails.sh：总结数由 `$CONTRACT` 推导；CONTRACT 表补 model/domain-token 列。
- restrict-bash-by-agent.sh：`date +%s` 失败 fail-closed；补 `rm -r -f` 变体正则；approval mode 校验；mtime `>=`；`--base-url` 引号。

### 补录（Codex 返回后新增）
- **F18 [N13, HIGH]** 审批分支先校验精确 launcher 与完整命令形态，再消费 token；弃 `playwright …` 任意位置匹配。
- **F19 [N12]** 契约删 BLOCK 里的"missing input"，BLOCK 仅表既定失败；NEEDS_INPUT 专用缺输入/待裁决。
- **F20 [N14]** CI 用 tracked 脱敏 settings fixture 验注册；本地集成测试验真实安装态。
- **F21 [N15]** 统一 E2E 目标解析：dispatcher 提供已解析 baseURL + 结构化 allowed-host，hook 不再依赖 `$BASE_URL` 展开。
- **F22 [N16]** security-checklists 标注并更新 OWASP 现行版本，SSRF 显式入表。
- **F23 [N17]** handoff 邻接补实现环节（architect → 实现 → review → 复审 → e2e）。
- **F24 [N18]** 触发夹具：加派发 harness 或删除并撤"single source"声明。
- **F25 [N19]** code-reviewer 加 UNKNOWN/NOT VERIFIED 规则，或要求 dispatcher 提供审计/许可证结果。

### 依赖图
- F1（agent_type 实证）→ 前置：一切依赖 Bash 门禁真实生效的修复（F2 的测试、F5、F9、F11、F18）。
- F18（N13 审批绕过）→ 依赖 F1（归因正确）与 C2 的 approvals 拦截，属同一条信任链。
- F3（e2e 沙箱决策）→ 用户裁决后才动 e2e-runner.md。
- F14（报告迁移）→ 依赖本报告写完（即现在），且须避开并发会话仍在写的文件。

### 总工作量估算
- Phase 1：0.5–1 天（实证优先，含一个真实抓包）
- Phase 2：0.5–1 天
- Phase 3：1–1.5 天
- Phase 4：0.5 天（机会性）
- 补录（F18–F25）：1–1.5 天
- **合计（含补录）：3–5 天**

---

**Verdict:** BLOCK — 承重墙（agent_type 实证 + config 绕过 + N13 审批绕过）未合拢前不应视为闭环；两个 CRITICAL 已修、token 契约已冻结，整体健康度较复审开始时显著改善。
