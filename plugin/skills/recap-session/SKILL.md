---
name: recap-session
description: Use when you need a printed recap (no file written) of what happened in a past Claude Code session by reading its raw `.jsonl` transcript from `~/.claude/projects/`. Also use when the user says "recap session", "summarize session", "pull session summary", "what happened in that session", "summarize the jsonl", "read session file", "what did we do last session", or "continue from a dead/crashed session".
---

# Recap a Claude Code Session from its Raw `.jsonl`

Reconstruct a readable summary of any Claude Code session by parsing its raw transcript log. Use this to recover context from a previous/crashed session, hand off to a fresh context window, or audit what an agent actually did.

This is for **raw `.jsonl` transcripts** (the verbatim message log Claude Code writes per session). To turn a transcript into a session file instead, use `/agent-ops:session-from-transcript`. For the curated session `.md` files used to update plugins, use `/agent-ops:session-analysis`.

## Where session files live

Each repo's transcripts live in a folder under the Claude projects dir, named by replacing every non-alphanumeric character of the repo's absolute path with `-`:

```
<repo>            = /home/dev/code/my-repo        (Windows: C:\code\my-repo)
project dir name  = -home-dev-code-my-repo        (Windows: C--code-my-repo)
full path         = <CLAUDE_PROJECTS>/-home-dev-code-my-repo/<session-uuid>.jsonl
```

Resolve `<CLAUDE_PROJECTS>` in this order: `$CLAUDE_PROJECTS` → `$CLAUDE_CONFIG_DIR/projects` → `$HOME/.claude/projects`. The config dir may be non-default — always resolve it from the env vars above; never assume `~/.claude`.

Each `<session-uuid>.jsonl` is one session, one JSON object per line.

## Fastest path — the bundled script

A self-contained helper is bundled with this skill. It prints header, titles, record counts, timespan, the human's typed prompts, and the full conversation flow:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/recap-session/scripts/recap.sh" --list            # recent sessions for $PWD's repo
bash "${CLAUDE_PLUGIN_ROOT}/skills/recap-session/scripts/recap.sh" --latest          # recap newest session for $PWD's repo
bash "${CLAUDE_PLUGIN_ROOT}/skills/recap-session/scripts/recap.sh" /abs/path/to/<uuid>.jsonl
```

For large transcripts (multi-MB), pipe to a file and `Read` it rather than dumping to the terminal:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/recap-session/scripts/recap.sh" <file> > "${TMPDIR:-/tmp}/recap.txt"
```

If `$CLAUDE_PLUGIN_ROOT` is unavailable (e.g. running from a non-plugin context), call the inline `jq` recipes below directly.

## Inline recipes (use when the script isn't reachable)

Set `FILE` to the target transcript, then run any of these.

**1. Inspect first** — titles, record-type counts, timespan:
```bash
jq -r 'select(.type=="ai-title")|.aiTitle' "$FILE" | awk '!seen[$0]++ && NF'   # auto-titles
jq -r '.type // "?"' "$FILE" | sort | uniq -c                                  # record types
jq -r 'select(.timestamp)|.timestamp' "$FILE" | sed -n '1p;$p'                 # first + last ts
```

**2. The human's actual asks & steering** — typed string prompts only, no slash-command expansions, no tool results, no meta:
```bash
jq -r '
  select(.type=="user" and ((.isMeta // false)|not) and (.message.content|type=="string"))
  | .message.content
  | select(test("^\\s*<(command|local-command)")|not)
  | select(length>0)' "$FILE"
```

**3. Full conversation flow** — user + assistant text + compact tool calls, tool-result noise dropped:
```bash
jq -r '
  select((.type=="user" or .type=="assistant") and ((.isMeta // false)|not))
  | .message.role as $role
  | (.message.content) as $c
  | if ($c|type)=="string" then
      (if ($c|length)>0 then "[\($role)]: " + $c else empty end)
    elif ($c|type)=="array" then
      ( $c[]
        | if .type=="text" then "[\($role)]: " + .text
          elif .type=="tool_use" then "[\($role) →tool] " + .name + ": " + ((.input|tostring)[:160])
          else empty end )
    else empty end' "$FILE" | grep -v '^\[.*\]: $'
```

## Transcript structure reference

One JSON object per line. Key record types and where the text lives:

| `.type` | Meaning | Where the content is |
|---------|---------|----------------------|
| `user` | User turn OR tool result | `.message.content` — **string** = typed prompt; **array w/ `tool_result`** = tool output (skip) |
| `assistant` | Model turn | `.message.content[]` — items `.type=="text"` (prose) or `.type=="tool_use"` (`.name` + `.input`) |
| `ai-title` | Auto-generated session title | `.aiTitle` (one per turn; dedupe & take last) |
| `last-prompt` | Pointer to leaf message | `.leafUuid` (no text) |
| `attachment`, `file-history-snapshot`, `system`, `mode`, `queue-operation` | Harness metadata | ignore for recaps |

**Discriminators that matter:**
- Real typed prompts: `type=="user"` AND `isMeta` is null/false AND `content` is a **string** AND does not start with `<command` / `<local-command`.
- Tool results masquerade as user messages — `content` is an **array** whose first item is `type=="tool_result"`. Always skip these.
- `isMeta: true` marks injected caveats and command bodies — skip for the human-asks view.
- The session UUID is in `.sessionId` on most records and matches the filename.

## Producing the recap (what to write)

After extracting, synthesize — don't just dump the flow. A good recap has:

1. **Header** — session id (short), date, UTC timespan, auto-title.
2. **Goal** — the opening typed prompt, verbatim or tight paraphrase.
3. **What got done** — concrete outcomes: files changed, commits (with hashes if present in tool calls/text), decisions made. Prefer a table when there are many.
4. **Where it stopped / final state** — was it mid-task? blocked? An `API Error`, repeated "Continue from where you left off", or `No response requested.` at the tail means the session **died mid-flight** — say so explicitly and name what was unfinished.
5. **User steering & corrections** — quote the human's redirects (from recipe #2). High-signal for handoff.
6. **Next step** — offer to resume where it stopped.

## Critical rules / gotchas

- **A pasted PowerShell one-liner (`Get-Content` / `ConvertFrom-Json`) does not run in bash/zsh.** Translate its intent to the `jq` recipes above. Requires `jq` (macOS `brew install jq`, Debian/WSL `apt install jq`, Git Bash `winget install jqlang.jq`).
- **A session may ask you to recap a *different* session.** The filename in the prompt is the target; don't assume it's the current session. (A common pattern: the user reuses the same prompt template and only swaps the file path.)
- **`API Error: Usage credits required for 1M context` is a billing-tier gate, not a token-count problem.** It fires on the 1M-context tier regardless of conversation size. If you see a session die on it, note that `/model` (switch to standard 200k) clears it without credits. This is itself a frequent reason sessions crash mid-task and need recapping.
- **Don't dump multi-MB flows into the terminal** — write to `${TMPDIR:-/tmp}` and `Read`. `head`/`tail` closing a `jq` pipe is harmless (SIGPIPE), but pair with `|| true` under `set -o pipefail`.
- **Tool-result arrays are the bulk of a transcript** — always filter them out or the recap drowns in noise.
- **Multiple `ai-title` records** appear (one per turn); dedupe and take the latest as the canonical title.

## Reference

- Bundled helper: `scripts/recap.sh` (this skill dir)
- Write a session file from a transcript: `/agent-ops:session-from-transcript`
- Mine curated session `.md` files: `/agent-ops:session-analysis`
