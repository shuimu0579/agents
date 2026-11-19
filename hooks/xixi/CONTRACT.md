# _xixi Hook Contract

> Source of truth for the interface between the `_xixi` agent prompt
> (`~/.claude/agents/_xixi.md`) and its clipboard-delivery hooks.
> If you change a hook's status strings or paths, update this file AND the agent prompt together.

## Components

| Role | Path | Event |
|------|------|-------|
| Agent prompt (consumer) | `~/.claude/agents/_xixi.md` | — |
| PreToolUse gate | `~/.claude/agents/hooks/xixi/restrict-write.sh` | `PreToolUse` matcher `Write` |
| PostToolUse delivery | `~/.claude/agents/hooks/xixi/copy-on-write.sh` | `PostToolUse` matcher `Write` |
| Shared path rules | `~/.claude/agents/hooks/xixi/common.sh` | sourced |
| Clipboard backend | `~/.claude/agents/scripts/copy-prompt.sh` | invoked |

## Registration

Registration is required. This file existing does not register the hook, and a
green suite does not prove the host is enforcing it.

| Host | Loaded config | Notes |
|------|---------------|-------|
| Claude Code | `~/.claude/settings.json` | Hand-registered 2026-10-20, after the Otty and prefer.py groups. Timeouts set 2026-10-21. PreToolUse `Bash` → `restrict-bash-by-agent.sh` (timeout 5); PreToolUse `Write|Edit` → `restrict-mutator-write.sh` (timeout 5); PreToolUse `Write` → `xixi/restrict-write.sh` (timeout 5); PostToolUse `Write` → `xixi/copy-on-write.sh` (timeout 15). Each command is one unquoted `~/.claude/agents/hooks/...` word. Claude matchers stay `Write` / `Write\|Edit`; Grok's native `write` alias is only in `agent-gates.json`. |
| Grok | `~/.grok/hooks/agent-gates.json` | `compat.claude.hooks` is off, so Claude settings hooks do not run. Matcher must include the native tool name `write` (`Write` aliases to `search_replace` only). The two xixi commands use the same timeouts: restrict-write 5, copy-on-write 15. |

`hooks.json` is a non-loaded mirror. Do not edit it expecting effect.

Reviewed 2026-10-21 against the live files, after a Codex `gpt-6-astra` run that hit its 900s deadline with an empty final answer (job `audit-mvgiadmw-r5fby6`). Later the same day the four fleet commands got the timeouts in the table above. The same day's follow-up requires `discard_xixi_temp` to parse exactly one JSON object, accept only an unambiguous top-level `_xixi` or `xixi`, and remove the file only when the single tool path (`file_path` or `path`) is `/tmp/xixi-prompt-<8 alnum>`. An unparsed payload warns and leaves the file. None of the four commands set `onFailure`. Official Claude hooks docs require v2.1.295 or later for `onFailure: "block"`; this machine's `claude --version` is 2.1.285, and without that field a timeout or a hook that cannot start lets the tool call continue. Grok's hook reference has no `onFailure` field; a timeout or crash fails open. `tests/hooks.test.sh` and `tests/hook-e2e.test.sh` require timeout 5 on the Bash and `Write|Edit` commands. `tests/xixi-hooks.test.sh` requires timeout 5 and 15 on the two xixi commands, including `agent-gates.json` when that file exists. None of these suites start Claude Code or Grok. A green suite still does not prove either host spawned the hook.

## PreToolUse gate — `restrict-write.sh`

When `agent_type` or `subagentType` ∈ {_xixi, xixi}, allows Write ONLY to:

```
/tmp/xixi-prompt-[A-Za-z0-9]{8}
```

Hardening:
- Deny **every pre-existing path** before reserve: regular file, empty file, directory, FIFO, symlink, hard link alias, anything.
- **Exclusive reserve** via Python `O_CREAT|O_EXCL|O_NOFOLLOW`, mode `0600`.
- After reserve, re-validate the inode before allowing Write: regular file, size `0`, `nlink == 1`, owned by current uid, not world-writable, not a symlink.
- `jq` missing and the payload names `_xixi` / `xixi` → fail closed (`exit 2`). A non-empty payload that is not exactly one JSON object, a non-string identity, or a NUL → `rule:schema` (`exit 2`). Two different non-empty spellings stay `rule:field-conflict`.
- `common.sh` missing/unreadable/missing required helpers → fail closed (`exit 2`).
- **Residual TOCTOU:** the model Write API itself does not expose `O_NOFOLLOW`. A concurrent attacker who replaces the inode after PreToolUse but before the actual Write may still race. This hook narrows the window; it does not claim perfect kernel-enforced write sandboxing.
- **Attribution prerequisite:** the sandbox applies when the identity field is `_xixi` or `xixi`. Claude sends `agent_type` and `tool_input`. Grok sends `subagentType` and `toolInput`. The hook reads both spellings. An empty string does not hide the other spelling. Two different non-empty values deny (`rule:field-conflict`). A non-string identity, a NUL, or more than one JSON value is `rule:schema`. Missing **both** identity fields is still main-session pass-through (same as the Bash gate). If a harness omits both, this gate does not constrain `_xixi`. Tests construct their own payloads, so they cannot detect a host that drops the field.

  What **is** covered: `tests/xixi-hooks.test.sh` pins the attribution matrix at the hook boundary — snake_case and camelCase `_xixi` / bare `xixi` outside the sandbox are denied, another agent is passed through, an absent identity is passed through as main session, a boolean `tool_input` does not hide `toolInput`, a non-string `agent_type` is denied, and concatenated JSON is denied.

  What is **not** covered, and must be checked by hand after any Claude Code or Grok upgrade:

  1. Dispatch `_xixi` with a real prompt and let it Write its `/tmp/xixi-prompt-<8-alnum>` file.
  2. Confirm the hook actually saw `_xixi`, not an absent identity.
  3. Ask `_xixi` to Write one path outside the sandbox and confirm exit 2.

  If step 2 shows the identity was absent, the sandbox is inert and `_xixi` must be treated as
  unconstrained until the harness is fixed — do not rely on the green test suite.

## PostToolUse delivery — `copy-on-write.sh`

Requires **path shape + identity ∈ {_xixi,xixi}** (`agent_type` or `subagentType`). Opens once with `O_NOFOLLOW` (Python), validates regular file, `nlink == 1`, bounded size, copies from bytes, unlinks. A non-object `tool_input` must not abort the script; `toolInput` is still read.

Failure handling:
- `common.sh` missing/unreadable for a parsed `_xixi` / `xixi` object → emit `⚠️` fallback status instead of silent success, then remove the sandbox file when that object's single tool path matches.
- `jq` missing, malformed JSON, or a payload that is not one JSON object: never copy and never delete. If the raw text still names `_xixi` and carries a sandbox `file_path`, emit `⚠️` fallback status when possible.
- `discard_xixi_temp` removes `/tmp/xixi-prompt-<8 alnum>` only when jq parses one object, the top-level identity is unambiguously `_xixi` or `xixi`, and exactly one tool path (`file_path` or `path`, on `tool_input` or `toolInput`) is that file. A nested identity, another agent, a non-object, or two different paths leaves the file. The path must not be a symlink and must not contain `..`, a newline, or a carriage return.
- A non-string identity or a NUL warns (`invalid attribution`), does not copy, and does not delete.

### Status schema

| `additionalContext` | Agent action |
|---------------------|--------------|
| `✅ … copied … do NOT paste` | Final: `✅ 改良后的 prompt 已复制到剪贴板`. No body. |
| `⚠️ …` | Paste full prompt + `⚠️ 剪贴板复制失败…` |
| no status | Same as `⚠️` |

## Bash mutator gate

`~/.claude/agents/hooks/restrict-bash-by-agent.sh` — single simple command, allowlists, no shell meta. Privileged e2e ops need one-shot files:

```
~/.claude/agents/hooks/approvals/with-deps    # playwright install --with-deps
~/.claude/agents/hooks/approvals/snapshots  # --update-snapshots
```

Create from main session (mtime within 300s); hook deletes after one use.

## Fail-safe

Agent NEVER pastes body on `✅`; ALWAYS pastes on anything else including missing status.
