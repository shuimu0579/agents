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
- Deny **every pre-existing path** before reserve: regular file, empty file, directory, FIFO, symlink, hard link alias, anything.
- **Exclusive reserve** via Python `O_CREAT|O_EXCL|O_NOFOLLOW`, mode `0600`.
- After reserve, re-validate the inode before allowing Write: regular file, size `0`, `nlink == 1`, owned by current uid, not world-writable, not a symlink.
- `jq` missing OR malformed JSON naming `_xixi` / `xixi` → fail closed (`exit 2`).
- `common.sh` missing/unreadable/missing required helpers → fail closed (`exit 2`).
- **Residual TOCTOU:** the model Write API itself does not expose `O_NOFOLLOW`. A concurrent attacker who replaces the inode after PreToolUse but before the actual Write may still race. This hook narrows the window; it does not claim perfect kernel-enforced write sandboxing.

## PostToolUse delivery — `copy-on-write.sh`

Requires **path shape + `agent_type` ∈ {_xixi,xixi}**. Opens once with `O_NOFOLLOW` (Python), validates regular file, `nlink == 1`, bounded size, copies from bytes, unlinks.

Failure handling:
- `common.sh` missing/unreadable for raw `_xixi` payloads → emit `⚠️` fallback status instead of silent success.
- `jq` missing or malformed JSON: never copy. If raw payload still names `_xixi` and carries an `_xixi` path, emit `⚠️` fallback status when possible.

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
