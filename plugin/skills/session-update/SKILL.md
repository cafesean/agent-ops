---
name: session-update
description: Use when logging progress to the active session file — the standard end-of-task session log for workers. Appends a detailed, retrieval-friendly update block (changes, root cause, commits, files, commands) and refreshes Decisions, Lessons Learned, Architecture Issues, User Steering and Next Steps. Triggers include "session update", "update the session", "log progress", "write the session log", "capture lessons", "record this debugging", or a worker finishing a task.
model: sonnet
---

# Session Update

Append to the active session file. Session files feed later recall and vector search, so
every section must be self-contained, specific and detailed. This is the session log a
worker writes at the end of each task.

## Step 0: Resolve locations

```bash
eval "$(bash "${CLAUDE_PLUGIN_ROOT}/skills/session-start/scripts/locations.sh")"
echo "$SESSIONS_DIR | $SPECS_DIR | $LOC_SOURCE"
```

Order: `.agent-ops.json` → `COS_SESSIONS_DIR`/`COS_SPECS_DIR` in the agent-ops config →
`./sessions`, `./specs`. Details: [locations](../session-start/references/locations.md).

## Step 1: Find the active session

Read `$CURRENT_SESSION` (one filename per line; several may be active). Match the `[tag]`
to the current work or to `$ARGUMENTS`. One match → use it; ambiguous → list and ask inline.
None → run `/agent-ops:session-start` first (no tracker yet is normal on first use).

## Step 2: Frontmatter

If the file has no YAML frontmatter (legacy), add it per
[file format](../session-start/references/file-format.md).

## Step 3: Append an update block

`### Update — YYYY-MM-DD HH:MM` with What Changed, Detailed Problem Analysis (when
debugging), Implementation Details, Commit Log, Files Changed, Git Status and Commands Run.
Exact formats: [update format](references/update-format.md). Use real timestamps (`date`).

## Step 4: Refresh standing sections

SDK Notes, Architecture Issues (with status), Context Documents, Lessons Learned (topics,
applies-to, confidence, evidence), User Steering & Corrections (user's exact words),
Decisions (why + alternatives), Next Steps. Same reference file.

## Step 5: Frontmatter fields

Update `last_updated`, append new `commits`, refresh `tags`, `status`, `sdk_touched`,
`apps_touched`, `specs`.

## Rules

- Specific beats generic: exact errors, function names, file paths, commands and results.
- Record what did not work and why — failed approaches are retrieval gold.
- Never rewrite earlier update blocks; append.
- Durable rules discovered here also go into the repo's `CLAUDE.md`.
