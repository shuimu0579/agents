---
plugin: grill
version: 1.2.3
date: 2026-08-09
target: /Users/suimumacmini/.claude/agents
style: Hard-Nosed Critique + Roadmap
addons: []
agents: [recon, architecture, error-handling, security, testing, codex-rereview]
---

# Grill Report — agent 舰队修改内容复审 (2026-08-09)

> **复审对象**：2026-08-09 收敛 + 整改的修改内容（4 agent、`guardrails.sh`、`hooks/`、`rules/`、CI、`archive/`）。
> **审查通道**：`grill:recon` 现状调查 → `grill:architecture` / `grill:error-handling` / `grill:security` / `grill:testing` 四深度代理 + Codex (gpt-5.6-sol) 独立复审 pass。全部 read-only。
> **标尺**：官方 Claude Code sub-agent schema + 奥卡姆剃刀 + 「修改引入的问题」而非全量重审。
> **风格**：Hard-Nosed Critique + Roadmap（用户选择）。

---

## 0. 总判（一段话）

**收敛本身干净利落：4-agent 已在运行时真正生效（6 个退役 agent 类型消失）、guardrails 本地 0 FAIL/0 WARN、model 政策全链路一致、hooks 已注册且有 21 例行为测试。但舰队唯一的运行时强制层——Bash 门——当前处于 fail-open 状态：hook 文件丢了执行位（`0644`）却作为 command hook 注册，直接执行退出 126，`bypassPermissions` 下 126 不阻断。即使恢复执行位，该门还有三个已实证/已论证的绕过向量（换行注入、生产保护冒号截断 + config 嵌入、approval 文件自写伪造），且 allowlist 与 e2e-runner prompt 的自洽规则正好相反。同时，「门禁全绿」是误导性的：model 政策、Verdict 末行、完整 token 家族、`triggers.yml`、`agent_type` 归属统统没有被真正的门覆盖——CI plain 模式跑不过任何 WARN 级检查。**

**Verdict: BLOCK**（security agent: VULNERABLE；error-handling: NEEDS_INPUT；Codex: BLOCK）。

---

## 1. 🔴 头条发现 — Bash 门运行时 fail-open（R1，已实证）

`settings.json:199` 把 `~/.claude/agents/hooks/restrict-bash-by-agent.sh` 注册为 PreToolUse Bash command hook（timeout 5s）。但该文件当前是 **`-rw-r--r--`（0644，无执行位）**，git 基线是 `100755`——执行位在本轮修改中丢失。直接调用实测：

```bash
$ hooks/restrict-bash-by-agent.sh
(eval):1: permission denied   # exit 126
```

Claude Code 的 PreToolUse 只认 **exit 2 阻断**；`bypassPermissions`（settings.json:317）下，126 是非阻断错误 → **所有 allowlist / 生产保护 / approval 检查在运行时全部失效**。`grill:security` 代理的实证观察与此一致：它是 review-only 的 security-reviewer（hook 应无条件拦截），但本轮会话里它的 Bash 调用全部通过。

**为何测试全绿却没人发现**：`hooks.test.sh` 和 CI 都用 `bash hooks/restrict-bash-by-agent.sh` 显式调用（绕过执行位），测试的是**脚本逻辑**，从不验证「settings.json 直接执行」这条真实路径。Codex 建议 CI 增加 `[ -x hooks/restrict-bash-by-agent.sh ]` 并直接执行。

---

## 2. Critical / High 发现（附利用路径）

### C1 — 运行时 Bash 门 fail-open（exec bit 丢失）
**证据**：`hooks/restrict-bash-by-agent.sh` mode `0644`（verified `ls -l` + 直接执行 `exit 126`）；注册于 `settings.json:199`；`bypassPermissions` 全局默认。**影响**：门等于没装。**修复**：恢复 `100755`；CI 加 `[ -x ]` 断言 + 直接执行而非 `bash file`。

### C2 — 换行注入绕过 allowlist（security 实证）
**证据**：`restrict-bash-by-agent.sh:46` 先 `tr '\n' ' '` 归一化再查 allowlist/denylist，但 Bash 执行的是原始多行串；`:87` 的 `\n|\r` 检查因此永远吃不到换行（先被归一化了）。实证 payload：`{"tool_input":{"command":"playwright test\nrm -rf /tmp/important-dir"}}` → **exit 0 放行**；后续行原样执行。denylist 的 `^` 锚点只看归一化后字符串开头。**影响**：allowlist 对多行命令完全失效——而这正是 Bash 最常见的形态。**修复**：归一化**前**对原始命令 fail-closed 拒绝任何 `\n`/`\r`，或对原始串做 allowlist 并要求单 token argv。

### H1 — Allowlist 与 e2e-runner prompt 正好相反（三代理一致实证）
**证据**：`e2e-runner.md:38,61` 规定「用 `node_modules/.bin/playwright` 或 `npx --no-install playwright`；禁止裸 `npx playwright`（会自动安装）」。`restrict-bash-by-agent.sh:162-163` 只匹配 `^(npx)?playwright (test|...)`。实证：
- `npx --no-install playwright test` → **exit 2（被拦）**
- `node_modules/.bin/playwright test` → **exit 2（被拦）**
- `npx playwright test`（prompt 明令禁止）→ **exit 0（放行）**

**影响**：强制层逼 agent 走它自己警告过的自动安装路径。**修复**：allowlist 加 `node_modules/\.bin/playwright` 与 `npx --no-install playwright`，拒绝裸 `npx playwright`；同步改测试。

### H2 — 生产保护两个绕过向量
**(a) 冒号截断（error-handling 实证）**：`restrict-bash-by-agent.sh:133-149` 用 `sed 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[:/].*##'` 把 host 在第一个 `:` 处截断。实证：
- `BASE_URL=http://localhost:3000.evil.com` → host `localhost` → **放行**
- `playwright test --base-url=http://localhost:3000.evil.com` → **放行**

**(b) config 嵌入（security）**：e2e-runner 持 Write；`settings.json:206-215` 的 Write hook 只拦 `*.md`，不拦 `playwright.config.ts`。agent 可写一个指向生产的 config 再跑 `playwright test`（无内联 URL、无 `BASE_URL` env）→ 门放行。**影响**：e2e-runner.md:159 宣称的「独立 fail-close 生产保护」对生产目标不成立。**修复**：正确解析 authority（整段 `host:port` 归一后精确匹配，非盲截）；hook 解析磁盘上生效的 `playwright.config.*` 的 baseURL，或对无 `--base-url` 的 `playwright test` 一律要求 config 已证明本地。

### H3 — 一次性 approval 可被 gated agent 自写伪造（security + Codex）
**证据**：`e2e-runner.md:40` 依赖 `hooks/approvals/with-deps` 一票制；但 e2e-runner 有 `Write/Edit`（`:23`），approval 文件在它可写目录且无扩展名 → Write PreToolUse hook 不拦。agent 先 `Write` `approvals/with-deps`，再消费。**影响**：`approvals/README.md` 的「orchestrator-only」是 prompt 级约束，非权限边界。**修复**：加 Write/Edit PreToolUse 规则拒绝写入 `hooks/approvals/*`；`consume_approval` 校验文件属主/创建 uid；approval 目录移到 agent 可写集之外。

### H4 — 整门依赖的 `agent_type` 归属未端到端验证
**证据**：`restrict-bash-by-agent.sh:67-77` 全靠 harness 注入 `agent_type` 精确匹配；空值 → `exit 0` 放行（`:75`）。`hooks.test.sh:29` 是**手工注入** `agent_type` 的合成 payload，无法发现真实 mismatch。security agent 实证：review-only 的 Bash 调用未按 `:68` 被拦（虽与 C1 部分混淆）。**影响**：若真实 payload 中 `agent_type` 为空，门对每个 agent 都放行。**修复**：端到端测试（真实 dispatch e2e-runner / review-only agent 断言 deny/allow）+ hook 内记录 `agent_type`。

### H5 — CI 落地即死：`archive/` 未提交 + guardrails 崩溃（error-handling 实证）
**证据**：`archive/` 是 untracked（`git ls-files archive/` 为空）；`guardrails.sh:231` `ARCHIVE_MDS="$(find archive ...)"` 在目录缺失时 `find` 退出 1，`set -Eeuo pipefail` 让脚本在汇总前崩溃（实测仅打印 `==> guardrails: auditing ...` 即 exit 1）。新 CI checkout 没有 `archive/` → **下一个 push 门禁当场死**。**修复**：把 `archive/` 提交进仓库，或 `[[ -d archive ]] || ARCHIVE_MDS=0`。两者都要做（提交前 CI 一直红）。

### H6 — 输出契约 token 表 50% 过时（architecture H1 + Codex R4）
**证据**：`agent-output-contract.md:25-30` 写 security-reviewer=`SAFE/NEEDS_REVIEW/VULNERABLE`、e2e-runner=`PASSING/QUARANTINE/FAILING`；但 `security-reviewer.md:104` 实际输出 `APPROVE | APPROVE WITH CHANGES | BLOCK`、`e2e-runner.md:195` 实际输出 `GO | NO-GO | QUARANTINE | NOTHING_TO_DO`。`guardrails.sh:90` 只搜宽泛的 `Recommendation:` / 单个 `QUARANTINE`，永远发现不了整套 token 家族漂移。**影响**：按契约解析的编排器会误读 50% 的舰队报告；「single source of truth」名存实亡——prompts 才是实际真相源。**⚠ 方向待裁决**（见 §6 决策项）：A=把契约对齐 prompts（APPROVE/GO 族）；B=把 prompts 对齐契约（SAFE/PASSING 族）。Codex 建议 B，architecture 建议 A。**我的建议**：security 已刻意并入 code-reviewer 的 APPROVE 族（`security-reviewer.md:98` 明写 "Same severity tags as code-reviewer"），e2e 的 `GO/NO-GO` 族又和 `**Verdict:** GO` 撞词（L3）。折中：**security→A（契约改 APPROVE，保持合并）；e2e→B（prompt 改 PASSING 族，删 NOTHING_TO_DO，消撞词）**。

---

## 3. Medium 发现

| ID | 发现 | 证据 | 影响 |
|----|------|------|------|
| M1 | **Verdict 末行契约 0/4 合规 + 门不查位置** | `agent-output-contract.md:7` 要求末行；4 模板都放顶部（architect:120, code-reviewer:123, security:103, e2e:194）；`guardrails.sh:177` 只 `grep -qF` presence | 按末行解析的消费者读不到结论 |
| M2 | **model 政策 + 行数预算在 CI 是 advisory** | `guardrails.sh:272` `check_model` 只 warn；`:136-141` 400-800 行只 warn；CI 跑 plain（agents-ci.yml:17）永不 `--strict` | architect 换 inherit、e2e 丢 sonnet、700 行 agent 都能全绿合并 |
| M3 | **review-only 禁写工具在 tools: 省略时降级为 warn** | `guardrails.sh:116-117,144-145,155-157`：tools 省略 → 禁写循环对空串跑 `has_tool`（假），exact-match 跳过 | F2 要防的回归（reviewer 偷偷拿回 Bash）可绕过 |
| M4 | **hooks.test.sh 是 standalone，非端到端** | `hooks.test.sh:18-37` 合成 JSON 管道进脚本；不查 settings.json 注册、不查 `agent_type` 真实值、不查 deny-JSON 是否被 harness 尊重 | 未来反注册 hook 或坏 `agent_type`，CI 照样绿 |
| M5 | **hooks.test.sh 覆盖 ~半数 hook 分支** | 未测：空命令 fail-closed、转义 shell 元字符、无 jq 回退、坏 JSON、`git push/reset --hard/clean -fd`、`curl/wget/bash -c`、yarn/pnpm/bun、approval 过期 >300s、未知 agent 透传 | 正是未来加固提交最可能悄悄破坏的路径 |
| M6 | **`triggers.yml` 是死夹具** | `guardrails.sh:239-243` 只查 `-f` 存在；不解析 YAML、不对照 CONTRACT、不查正/负例非空 | 舰队变更后夹具漂移零失败 |
| M7 | **domain-token→Verdict 映射一致性无测试** | CONTRACT 只查单 token presence；prompts 里的映射表（e2e:189、code-reviewer:120-124 等）与契约表无人对照 | `QUARANTINE→GO` 这类改动会全绿通过 |
| M8 | **guardrails 发现模型 ≠ 运行时递归扫描** | `guardrails.sh:211` `find . -maxdepth 1`；Claude Code 递归扫 `~/.claude/agents/` | `docs/`、`tests/` 下新 `.md` 一旦带合法 frontmatter 即成 runtime agent，测试全绿 |
| M9 | **hooks.test.sh 本地跑会销毁真实 approval** | `hooks.test.sh:13-16,62-67` 截断+消费 `with-deps/snapshots`；EXIT trap 只清两个已知文件 | 有 pending approval 时本地跑一次即误删，下个特权 Bash 调用失败 |
| M10 | **hooks.test.sh 吞 stderr + 无 jq preflight** | `:30` `>/dev/null 2>&1`；无 jq 时 payload 空、hook 按主会话透传、结果混乱 | 失败无诊断；外部依赖未声明（guardrails.sh:19 故意避开 jq） |
| M11 | **注入前导语不在 mutator 上强制** | `guardrails.sh:184-193` preamble 检查只对 `review_only` flag | 唯一 mutator（e2e-runner）读最多不可信测试产物，却没有回归网 |
| M12 | **e2e QUARANTINE 双映射漂移** | `e2e-runner.md:189` `QUARANTINE→NEEDS_INPUT (显式接受) 否则 BLOCK`；契约表无条件 `NEEDS_INPUT (flaky)` | 未授权 QUARANTINE 被契约当「安全地询问」，prompt 却要硬停 |
| M13 | **guardrails 临时文件依赖（heredoc/here-string）** | `guardrails.sh:89-95,168,194,211` 经 `$TMPDIR` 物化 | 只读/noexec 沙箱里跑不起来（Codex 实测在此环境 heredoc 失败） |

---

## 4. Low 发现 + 正面确认

**Low：**
- **L1** `scripts/copy-prompt.sh:3` 孤儿：唯一消费者是已归档 `_xixi`（grill-report-2026-08-07.md 提及）；留则保留退役名。→ 移 archive/ 或删。
- **L2** `scripts/` 无测试（copy-prompt.sh 孤儿、verify-f4-key.sh 环境依赖）。
- **L3** e2e domain token `GO` 与 `**Verdict:** GO` 撞词（e2e-runner.md:194-199），唯一撞词 agent。
- **L4** `guardrails.sh:254-258` F2 检查与 CONTRACT 的 review-only 禁写重复。
- **L5** `agents/CLAUDE.md:29-41` 结构图漏 `docs/`（security-reviewer 依赖 `docs/agents/security-checklists.md`）。
- **L6** 四份审计报告堆在 repo root（`codex-*.md`、`grill-report-*.md`），是 grep 退役名噪声的最大来源；建议移 `docs/audits/`。
- **L7** e2e 模板存在性检查（presence-only），且 `templates/e2e.github-actions.yml.tmpl:18` 无条件跑 `--with-deps`，与 approval 门未交叉校验。
- **L8** jq 未声明依赖（ubuntu 预装，macOS 路径 `/usr/bin/jq`）。
- **L9** approvals TOCTOU：check→age→rm 并发下双放行（symlink-safe、path-safe）。
- **L10** `*.test`/`*.local` 后缀允许 LAN host 别名（RFC 6761/6762 保留 TLD，风险仅 LAN）。
- **L11** `settings.json:187-195` 内联 git-push hook 对含 `git push` 字样的任意命令误报（security 实证被误拦）+ 引号混淆可绕过（`git p'u'sh`）。
- **L12** `guardrails.sh:299` 硬编码 `(4 agent files)`，不随 CONTRACT 推导。
- **L13** Verdict 非加粗形式 `Verdict:` 也通过（contract 要求 `**Verdict:**`）。
- **L14** code-reviewer 缺显式 zero-findings 分支（security-reviewer.md:145 有，code-reviewer 只靠 Approval Criteria 隐含）。
- **L15** e2e-runner 在 review 后写 spec，邻接表无「再审」回路（rules/agents.md:39 的 substantive-change 条款会再触发，但图不画）。

**正面确认（收敛落地正确）：**
- ✅ 4-agent 运行时生效：`archive/*.md.disabled` 6 个，`*.md` 0 个；本会话 6 个退役 agent 类型已不可用。
- ✅ `guardrails.sh` 本地 **0 FAIL / 0 WARN**（plain + strict），CONTRACT 恰好 4 行。
- ✅ model 政策一致：frontmatter（architect:30 opus, code:24 sonnet, security:30 sonnet, e2e:24 sonnet）= `rules/agents.md:14` = `guardrails.sh:288`。D2 已落地。
- ✅ `restrict-bash-by-agent.sh` 已注册进 settings.json:199（运行时接线完成），`hooks.test.sh` 21/21 行为测试（逻辑层）。
- ✅ 4 agent 均保留注入前导语 + secret 截断规则；handoff 无 planner 残留。
- ✅ 新文件（codex-*.md、security-checklists.md）均无合法 agent frontmatter，未被误载为 agent。

---

## 5. 80/20 重写计划

**保留（已做对，别动）**：4-agent 结构、`.md.disabled` 停用、guardrails CONTRACT 表、D2 model 政策、e2e-runner 生产保护**意图**、security-reviewer 的 checklists 外置、approvals 一票制**意图**、prompt 的注入前导语与 secret 截断。

**重写/加固（20% 工作量解决 80% 风险）**：
1. **hook 执行路径**：恢复 `100755`；CI 直接执行 hook 而非 `bash file`；加 `[ -x ]` 断言。
2. **hook 核心**：归一化前拒绝 `\n`/`\r`；allowlist 与 prompt 对齐（.bin/playwright + `npx --no-install`，禁裸 `npx`）；生产 host 用正确 authority 解析（非冒号盲截）；approval 目录加 Write 拒写。
3. **契约冻结**：先冻结 token 词汇（裁决 A/B），再让 `agent-output-contract.md` 变成**被 guardrails 强制**的 superset——Verdict 末行、完整 token 家族、mapping 一致性都进门禁。
4. **门禁硬化**：CI 跑 `--strict`；model 政策与 review-only 禁写升 FAIL；`archive/` 提交或检查容缺；发现改递归。
5. **死代码**：`copy-prompt.sh` 归档、审计报告移 `docs/audits/`。

---

## 6. 优先 backlog（15 项，按 Impact × Risk ÷ Effort 排序）

| # | 项 | Sev | 影响 | 风险 | 工时 |
|---|----|-----|------|------|------|
| 1 | 恢复 hook 执行位 + CI `[ -x ]` 直接执行（C1） | CRIT | 高 | 高 | 5m |
| 2 | `archive/` 提交 或 guardrails 容缺（H5） | HIGH | 高 | 高 | 5m |
| 3 | 归一化前拒绝换行（C2） | HIGH | 高 | 高 | 10m |
| 4 | allowlist ↔ prompt 对齐（H1） | HIGH | 高 | 中 | 15m |
| 5 | 生产保护正确 host 解析 + config 嵌入缓解（H2） | HIGH | 高 | 中 | 30m |
| 6 | Write/Edit 拒写 `hooks/approvals/*`（H3） | HIGH | 高 | 中 | 15m |
| 7 | 裁决 token 方向 + 契约对齐 + 全家族进 guardrails（H6/M7） | HIGH | 高 | 中 | 20m |
| 8 | Verdict 移末行 ×4 + guardrails 位置断言（M1） | MED | 中 | 中 | 20m |
| 9 | CI 跑 `--strict`；model/review-only 禁写升 FAIL（M2/M3） | MED | 中 | 中 | 10m |
| 10 | E2E hook 测试：真实 dispatch 断言 `agent_type` deny/allow + 注册 grep（H4/M4） | HIGH | 中 | 高 | 1h |
| 11 | hooks.test.sh 分支补齐 + stderr + jq preflight + 隔离 live approvals（M5/M9/M10） | MED | 中 | 中 | 30m |
| 12 | `triggers.yml` 变真夹具（解析 + 对照）（M6） | MED | 低 | 中 | 20m |
| 13 | guardrails 递归发现（M8） | MED | 中 | 中 | 20m |
| 14 | 死代码：copy-prompt.sh + 审计报告移 docs/audits/（L1/L6） | LOW | 低 | 低 | 10m |
| 15 | QUARANTINE 双映射 + NOTHING_TO_DO + GO 撞词收尾（M12/L3） | MED | 低 | 低 | 10m |

---

## 7. 红旗 + Quick wins

**红旗：**
1. 舰队唯一的运行时强制层以非可执行文件注册——没有任何测试、CI、审查发现，直到 Codex 复审 pass 抓到。`bash file` 调用方式系统性掩盖了 exec-bit 问题。
2. token 词汇一天内翻转 3 次（SAFE→APPROVE→SAFE→APPROVE…），契约永远追不上；**不先冻结词汇，任何契约修复都会再次过时**。
3. 每个运行时控制（allowlist / 生产保护 / approval）要么可被 gated agent 自己的 Write 工具绕过，要么是 prompt 级约束——在 `bypassPermissions` 下，安全边界几乎全是建议。
4. 「门禁全绿」长期是误导：WARN 级检查（model 政策、行数、Verdict 位置）CI 全都不拦。

**Quick wins（<1 天）：** backlog #1–#6（全是小改动，合计 ~1.5h）。

---

## 8. Executive Summary

**一段判定**：收敛的**结构**是好的——4-agent 真正生效、门禁本地全绿、D2 落地、hooks 接线。但**运行时强制层 fail-open + 三个已实证绕过向量 + 契约 50% 漂移**意味着：当前「文档与门禁双全绿」的观感显著高于实际安全。最大风险不是文本写得差，而是**「约束存在但没被执行」**这个系统性模式在一个地方集中爆发（Bash 门），而门禁本身又无法发现它。

**Top 3 行动**：
1. **修执行位 + 提交 archive/**（#1+#2）——门要能跑，CI 要能跑。各 5 分钟，所有下游依赖。
2. **封三个绕过 + allowlist 对齐**（#3–#6）——换行注入、生产保护、approval 伪造、prompt↔门反转。这是让门从「形同虚设」变「真边界」的全部工作。
3. **冻结 token 词汇 + 让契约被强制**（#7+#8，CI strict 收口）——否则契约单源永远只是口号，编排器永远可能误读一半报告。

**置信度**：C1（exec bit→126）**High**（直接实证）；H1（allowlist 反转）**High**（三代理一致实证）；H2a（冒号截断）**High**（实证）；H5（archive 崩溃）**High**（实证）；C2（换行注入）**High**（security 实证，但 sandbox 相关性待真机确认）；H2b/H3（config 嵌入 / approval 伪造）**Medium**（设计分析，未端到端触发）；H4（`agent_type` 失效）**Medium**（实证但与 C1 混淆）。置信度提升靠：E2E hook 测试（真实 dispatch）+ 恢复执行位后重测。

**最大风险（一句话）**：恢复执行位前，门等于没装；恢复后，一个被 prompt 注入或配置错误引导的 e2e-runner 仍可借**换行注入**或**config 嵌入**以用户权限执行任意 Bash（含生产 money 路径），而 approvals 一票制可被它自己用 Write 伪造——舰队对「被攻破的 mutator」不 fail-closed。

---

## Fixing Plan

### Phase 1: Critical fixes (do immediately)
- **F1-1** — [CRITICAL/C1] hook 执行位：`chmod 755 hooks/restrict-bash-by-agent.sh`。同时 `tests/hooks.test.sh` 恢复 `755`（虽用 `bash` 调，保持一致性）。**文件**：`hooks/restrict-bash-by-agent.sh`。**Effort**: 5m。
- **F1-2** — [CRITICAL/C1] CI 直接执行 + 断言：`agents-ci.yml` 加 `test -x hooks/restrict-bash-by-agent.sh` 步骤，hooks 测试改为 `bash tests/hooks.test.sh`（保留）+ 新增一步直接 `hooks/restrict-bash-by-agent.sh </dev/null` 验证 exit 非 126。**文件**：`.github/workflows/agents-ci.yml`。**Effort**: 5m。
- **F1-3** — [HIGH/H5] `archive/` 未提交：`git add archive/` 与删除一起作为一次 consolidation 提交（否则 `git checkout .` 会复活旧舰队）；同时 `guardrails.sh:231` 改 `if [[ -d archive ]]; then ...; else ARCHIVE_MDS=0; fi` 容缺。**文件**：仓库、`tests/guardrails.sh`。**Effort**: 5m。

### Phase 2: High-priority fixes (this sprint)
- **F2-1** — [HIGH/C2] 换行 fail-closed：`restrict-bash-by-agent.sh` 在 `tr '\n' ' '` 之前，对原始 `cmd` 若含 `\n`/`\r` 直接 `exit 2`（或改 allowlist 作用于原始串 + 单 token argv）。**文件**：`hooks/restrict-bash-by-agent.sh` + `tests/hooks.test.sh`（加多行 payload 用例）。**Effort**: 15m。
- **F2-2** — [HIGH/H1] allowlist 对齐 prompt：允许 `node_modules/\.bin/playwright (test|show-report|codegen)` 与 `npx[[:space:]]+--no-install[[:space:]]+playwright ...`；拒绝裸 `^npx[[:space:]]+playwright` 除非带 `--no-install`。**文件**：`hooks/restrict-bash-by-agent.sh:162-163` + `tests/hooks.test.sh:48-49`。**Effort**: 15m。
- **F2-3** — [HIGH/H2] 生产 host 正确解析：替换 `sed 's#[:/].*##'` 为完整 authority 解析（剥 scheme、取 `host[:port]` 整体、host 精确匹配 `localhost|127.0.0.1|::1|*.test|*.local|*.staging`，拒绝 host 部分带任何额外 `.`）。并加 config-embed 缓解：hook 对无显式 `--base-url` 的 `playwright test`，读取工作目录 `playwright.config.*` 的 baseURL 一并校验。**文件**：`hooks/restrict-bash-by-agent.sh:133-149` + 测试。**Effort**: 30m。
- **F2-4** — [HIGH/H3] approval 目录拒写：settings.json 加 PreToolUse Write|Edit 规则（或收窄现有 Write 规则），拒绝 e2e-runner 写 `~/.claude/agents/hooks/approvals/*`；`consume_approval` 校验文件属主 uid == 主会话 uid。**文件**：`~/.claude/settings.json` + `hooks/restrict-bash-by-agent.sh`。**Effort**: 15m。
- **F2-5** — [HIGH/H6] token 契约收口（依赖决策 D-TOKEN）：按裁决方向（建议 security→APPROVE 族 / e2e→PASSING 族）一次性同步 `agent-output-contract.md` 表 + `security-reviewer.md:104,147` / `e2e-runner.md:189,194-199` + `guardrails.sh` CONTRACT token 列。**文件**：3 处 + guardrails。**Effort**: 20m。

### Phase 3: Medium-priority improvements (next sprint)
- **F3-1** — [MED/M1] Verdict 末行：4 个 agent 模板把唯一 `**Verdict:**` 移到 closing fence 前最后一行（Handoff 之后）；`guardrails.sh` 加「模板末行必须是 `**Verdict:**`」断言（或至少断言 `<file>` 内 `**Verdict:**` 后无其他模板段）。**文件**：4 agent + guardrails。**Effort**: 20m。
- **F3-2** — [MED/M2+M3] 门禁硬化：`agents-ci.yml` 跑 `--strict`；`check_model` 不匹配改 FAIL；review-only 在 tools 省略时也禁写（或 tools 省略 → FAIL 而非跳过）。**文件**：guardrails + CI。**Effort**: 10m。
- **F3-3** — [HIGH/H4+MED/M4] E2E hook 测试：新增脚本 dispatch 真实 e2e-runner / 一个 review-only agent 的 Bash 调用，断言门 deny/allow；hook 内 `echo "agent_type=$agent_type"` 到日志一次。**文件**：`tests/hooks.test.sh` 或新测试 + hook。**Effort**: 1h。
- **F3-4** — [MED/M5/M9/M10] hooks.test.sh 加固：补未测分支（空命令/转义元字符/无 jq/坏 JSON/destructive/网络/包管理器/过期 approval/未知 agent）；stderr 保留；jq preflight；本地跑改到临时 HOOK_ROOT。**文件**：`tests/hooks.test.sh`。**Effort**: 30m。
- **F3-5** — [MED/M6] triggers.yml 变真夹具：guardrails 解析 YAML（或用 python3），对照 CONTRACT 名、断言 positive/negative 非空。**文件**：guardrails + triggers.yml。**Effort**: 20m。
- **F3-6** — [MED/M8] guardrails 递归发现：`find . -name '*.md'`（排除 .git/archive/docs 白名单或按 frontmatter 判定），与 runtime 递归语义对齐。**文件**：guardrails。**Effort**: 20m。
- **F3-7** — [MED/M11] mutator 注入前导语进 guardrails（`e2e-runner` flag 加 preamble 断言）。**Effort**: 5m。

### Phase 4: Low-priority cleanup (when touching these files)
- **L1/L6** — `scripts/copy-prompt.sh` 移 `archive/` 或删；审计报告（`codex-*.md`、`grill-report-*.md`）移 `docs/audits/`。**Effort**: 10m。
- **L2/L4/L5/L7/L12/L13** — scripts 加测试或标注；删 F2 冗余检查；CLAUDE.md 结构图补 `docs/`；e2e 模板与 approval 交叉校验；guardrails 计数从 CONTRACT 推导；Verdict 位置断言顺带强制加粗。**Effort**: 30m。
- **L3/M12/L14/L15** — 随 D-TOKEN 决策一并收口（删 NOTHING_TO_DO、QUARANTINE 单映射、GO 撞词）；code-reviewer 补 zero-findings 分支；handoff 图加 e2e→code-reviewer 再审回路。**Effort**: 20m。

### Dependency graph
- **F1-3（archive 提交/容缺）必须在任何 CI 依赖之前**——否则 guardrails 在 CI 上根本跑不起来。
- **F1-1（执行位）先于 F3-3（E2E hook 测试）**——E2E 测试需要一个真能执行的门。
- **D-TOKEN 决策先于 F2-5（契约收口）与 F3-1（Verdict 末行）**——先冻结词汇，再改模板与契约，避免第三次翻转。
- **F2-1（换行 fail-closed）先于 F3-3**——E2E 测试的多行 payload 需要确定语义。

### Estimated total effort
- **Phase 1**: 0.25 天
- **Phase 2**: 1.5 天
- **Phase 3**: 2.5 天
- **Phase 4**: 1 天（opportunistic）
- **Total**: ~5 天（其中 Phase 1–2 ≈ 2 天覆盖全部 CRITICAL/HIGH）
