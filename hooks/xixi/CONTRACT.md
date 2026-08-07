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

## Registration (LIVE config)

**`~/.claude/settings.json` is the ONLY loaded config.** Point hooks at
`~/.claude/agents/hooks/...` (git-tracked). `hooks.json` is a non-loaded mirror.

## PreToolUse gate — `restrict-write.sh`

When `agent_type ∈ {_xixi, xixi}`, allows Write ONLY to:

```
/tmp/xixi-prompt-[A-Za-z0-9]{8}
```

Hardening:
- Symlink rejected (`[ -L ]` + shape check).
- Pre-existing non-empty targets rejected.
- **Exclusive reserve** via Python `O_CREAT|O_EXCL|O_NOFOLLOW` when possible, leaving an empty regular file for Write to truncate in place (narrows symlink race; residual cross-process races may remain if the host Write API replaces the inode).
- **Residual TOCTOU:** without kernel-enforced O_NOFOLLOW on the Write tool itself, a privileged concurrent attacker may still race; document this residual until the platform supports no-follow writes.
- jq missing → fail closed for `_xixi`.

## PostToolUse delivery — `copy-on-write.sh`

Requires **path shape + `agent_type` ∈ {_xixi,xixi}**. Opens once with `O_NOFOLLOW` (Python), validates regular file + size, copies from bytes, unlinks.

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
