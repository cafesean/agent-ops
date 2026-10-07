---
name: session-start
description: Use when starting a development session that should be logged to a session file (YAML frontmatter, RAG-friendly sections, active-session tracker). Triggers include "start a session", "session start", "new session file", "log this session", "begin session for X", or the start of a task a worker will report on with /agent-ops:session-update.
---

# Session Start

Create a session file for the work about to begin and register it as active.
Sibling skills: `/agent-ops:session-update` (log progress, the end-of-task log),
`/agent-ops:session-end` (close), `/agent-ops:session-from-transcript` (rebuild one after the fact).

## Step 0: Resolve locations

```bash
eval "$(bash "${CLAUDE_PLUGIN_ROOT}/skills/session-start/scripts/locations.sh")"
echo "$SESSIONS_DIR | $SPECS_DIR | $LOC_SOURCE"
```

Order: `.agent-ops.json` → `COS_SESSIONS_DIR`/`COS_SPECS_DIR` in the agent-ops config →
`./sessions`, `./specs`. Details: [locations](references/locations.md). Never refuse for
missing config — the defaults are valid; `mkdir -p "$SESSIONS_DIR"` before writing.

## Step 1: Name the file

`YYYY-MM-DD-[tag]-description.md` inside `$SESSIONS_DIR`. The square brackets are literal.

- **tag** — short, stable kebab-case: project, repo, feature area or activity (`[web]`, `[api]`, `[billing]`, `[infra]`, `[research]`).
- **description** — at most 4 plain words, one topic, no `and`, no ticket ids, no status words.

| Bad | Good |
|---|---|
| `p12-export-simplified-tickets-filed-first-two-stories` | `export-build-started` |
| `export-feature-spec-session-and-csv-format-review` | `export-feature-spec-session` |

## Step 2: Write the skeleton

Use the frontmatter and sections in [file format](references/file-format.md) — the same
schema `session-update` maintains. Take goals from `$ARGUMENTS`; ask inline only if unclear.
Fill `branch`, `projects`, `apps_touched` from the repo.

## Step 3: Register and confirm

1. **Append** the filename as a new line to `$CURRENT_SESSION` (create if absent; never overwrite — other sessions may be active).
2. Read the repo's `CLAUDE.md` (if present) and any spec in `$SPECS_DIR` relevant to the goal.
3. Confirm in one line: path written, and that `/agent-ops:session-update` logs progress.
