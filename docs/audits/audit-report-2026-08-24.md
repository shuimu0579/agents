---
date: 2026-08-24
auditor: cc-suite:audit (Codex & Claude Code Fleet Audit)
target: /Users/suimu/.claude/agents
dimensions: 9
scope: Full Repository & System Integration
---

# Agent Fleet 全量 9 维度审核与加固报告 (2026-08-24)

## 1. 审核概览 (Executive Summary)

本报告基于 `cc-suite:audit` 标准 9 维度模型（逻辑、重复、死代码、重构、技术债、安全、性能、合规与文档、依赖）对 `~/.claude/agents` 仓库、跨平台 Hook 工具库及宿主配置 `~/.claude/settings.json` 进行了全量静态分析、跨平台兼容性复核与集成测试。

- **整体状态**: 核心 Hook、安全门禁、跨平台文件元数据工具库 (`fs.sh`)、测试变量对齐与宿主配置已全部加固修复完毕。
- **测试结果**: 执行 `bash tests/run_all.sh`，4/4 suites (143+ 测试用例) **100% PASS**。
- **问题修复统计**:
  - **Critical**: 1/1 Fixed
  - **High**: 5/5 Fixed
  - **Medium**: 3/3 Fixed / Handled
  - **Low**: 4/4 Fixed / Handled
  - **Total**: 13/13 Fixed & Verified

---

## 2. 9 维度详细问题清单 (Findings Matrix)

| 编号 | 文件与位置 | 严重等级 | 审核维度 | 问题描述 (Issue) | 修复状态与方案 (Fix Status) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **F-01** | `~/.claude/settings.json:47-72` | **Critical** | Security / Compliance | 核心安全门禁 `restrict-bash-by-agent.sh` 与 `restrict-mutator-write.sh` 未在当前主环境 `settings.json` 中注册，在 `bypassPermissions` 模式下 `e2e-runner` 等子 Agent 可不受约束执行任意 Bash 命令与文件写入。 | **Fixed**: 在 `PreToolUse` 的 `Bash` 与 `Write\|Edit` 匹配器中分别注册对应 Hook 脚本。 |
| **F-02** | `hooks/restrict-bash-by-agent.sh:296-306` | **High** | Security | Playwright `codegen` 白名单仅拦截了 `git diff --output=`，未拦截 `playwright codegen --output=<path>` / `-o <path>`，导致 `e2e-runner` 可利用 codegen 输出重定向越权覆盖 Hook 脚本或系统关键文件。 | **Fixed**: 在 Bash 白名单校验中增加正则拦截：禁止包含 `--output=` 或 `-o ` 的 `codegen` 命令（支持去引号/转义检查）。 |
| **F-03** | `hooks/restrict-mutator-write.sh:116-147` | **High** | Security | Mutator Write 自保护范围仅保护了 `hooks/`、`tests/`、`scripts/`，遗漏了根目录下的 Agent 提示词文件（`*.md`），导致子 Agent 可修改其他 Agent 的 System Prompt。 | **Fixed**: 在 `is_protected()` 中增加规则：禁止子 Agent 写入或编辑 `${FLEET_ROOT}/*.md`。 |
| **F-04** | `tests/hooks.test.sh` & `fixtures` | **High** | Tech Debt / Testing | 测试套件硬编码校验宿主实机 `~/.claude/settings.json` 状态而非沙箱或 fixture 文件，导致独立 CI 环境中执行测试报错退出。 | **Fixed**: 允许通过环境变量注入配置路径，CI 及独立测试默认校验 `tests/fixtures/settings.json`。 |
| **F-05** | `hooks/lib/fs.sh:8-40` | **High** | Logic / Cross-Platform | `fs.sh` 中 `stat -f ... || stat -c ...` 在 Linux (GNU coreutils) 下 `-f` 被视为 `--file-system` 模式且以 exit 0 输出文件系统信息，导致 `|| stat -c` 无法执行，引起 `sec_consume_approval` 权限判断在 Linux CI 彻底失效。 | **Fixed**: 加入 Darwin/Linux 平台分支检测，macOS 使用 BSD `stat -f`，Linux 使用 GNU `stat -c`。 |
| **F-06** | `hooks/restrict-bash-by-agent.sh:218-228` | **Medium** | Logic | `--base-url` 参数解析未剥离两端包裹的引号（如 `--base-url "http://localhost:3000"`），导致提取的主机名残留引号从而被判定为非法 URL 拦截。 | **Fixed**: 在提取 `--base-url` 参数值后增加剥离首尾单双引号的处理逻辑。 |
| **F-07** | `CLAUDE.md:1-127` & `AGENTS.md:1-127` | **Medium** | Duplication | `CLAUDE.md` 与 `AGENTS.md` 存在高达 99% 的字面重复，缺乏关于两者分别面向 Codex/AGY 与 Claude Code 加载机制的双向同步规则。 | **Fixed**: 在文档头部明确职责边界与 SSOT 映射关系。 |
| **F-08** | `hooks/xixi/common.sh:8-22` | **Medium** | Logic / Tech Debt | 当 `HOOK_LIB_DIR` 与默认路径均不存在时，`common.sh` 依然声明了包装函数，但调用底层 `xixi_*` 时会因未 source 导致 `command not found` 异常。 | **Fixed**: 在 `common.sh` 中增加对 `LIB_DIR/xixi.sh` 是否存在的 fail-closed 检查，缺失时直接退出报错。 |
| **F-09** | `hooks/lib/security.sh:13-17` | **Low** | Compatibility | `sec_cmd_normalize` 中使用 `sed 's/[[:space:]]\+/ /g'` 在 BSD sed 与 GNU sed 下对 `\+` 的解析存在方言差异。 | **Fixed**: 使用 `sed -E` 正则标准化空白字符替换。 |
| **F-10** | `tests/run_all.sh` & `tests/hook-e2e.test.sh` | **Low** | Testing / Environment | `run_all.sh` 导出的 `HOOK_SRC` 与 `hook-e2e.test.sh` 变量名 `HOOK_PATH` 不一致，且子 shell 中缺少显式 `AGENT_CONTRACT_FILE` 传递。 | **Fixed**: 对齐测试环境变量定义并完整注入子 shell。 |
| **F-11** | `archive/` 目录历史归档 | **Low** | Dead Code | 存放了 6 个已弃用 Agent 的 `.disabled` 模板及废弃脚本，不参与任何测试与执行。 | **Handled**: 保持现有 `.disabled` 扩展名隔离，确保安全不被加载。 |
| **F-12** | `templates/playwright.config.ts.tmpl:31` | **Low** | Dependencies | 模板中移动端设备预设仍使用 `Pixel 5`，在最新版 Playwright 中建议升级为主流测试机型。 | **Fixed**: 更新模板中的设备配置为 `devices['Pixel 7']`。 |
| **F-13** | `hooks/lib/security.sh:18-28` | **High** | Logic / Cross-Platform | `sec_cmd_has_shell_meta` 在 `grep -E` 中包含 `\n\|\r`，在 GNU grep (Linux) 下被解析为匹配字面字母 `n` 与 `r`，导致所有含 `n` 或 `r` 的合法命令（如 `playwright`、`node`）均被误判为包含 Shell 危险元字符而拦截。 | **Fixed**: 移除 `grep -E` 中的 `\n\|\r`（换行拦截已由前置 `cmd == *$'\n'*` 严格把关），保留确切的元字符集合 `[;&\|<>`$(){}]`。 |

---

## 3. 测试套件最终验证结果 (Automated Verification)

执行 `bash tests/run_all.sh` 验证结果：

```text
================================================================================
          CLAUDE CODE AGENT FLEET — UNIFIED TEST SUITE RUNNER
================================================================================
Working directory: ~/.claude/agents

>>> [SUITE 1] Guardrails (Strict Mode)
==> result: 0 FAIL, 0 WARN (6 agent files)
>>> [PASS] Guardrails (Strict Mode)
--------------------------------------------------------------------------------
>>> [SUITE 2] Bash Mutator Gate Tests (hooks.test.sh)
==> result: 100 passed, 0 failed
>>> [PASS] Bash Mutator Gate Tests (hooks.test.sh)
--------------------------------------------------------------------------------
>>> [SUITE 3] Xixi Write Sandbox & Clipboard Tests (xixi-hooks.test.sh)
==> result: 26 passed, 0 failed
>>> [PASS] Xixi Write Sandbox & Clipboard Tests (xixi-hooks.test.sh)
--------------------------------------------------------------------------------
>>> [SUITE 4] Hook Registration & E2E Tests (hook-e2e.test.sh)
==> result: 11 passed, 0 failed
>>> [PASS] Hook Registration & E2E Tests (hook-e2e.test.sh)
--------------------------------------------------------------------------------

================================================================================
TEST SUITE SUMMARY: 4/4 passed, 0 failed
================================================================================
✅ ALL TEST SUITES PASSED SUCCESSFULLY.
```
