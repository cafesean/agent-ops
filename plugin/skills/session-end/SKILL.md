---
name: session-end
description: Use when wrapping up a development session — appends a closing summary (git, todos, accomplishments, problems, lessons, what is unfinished), folds durable lessons into CLAUDE.md, marks the file completed and removes it from the active-session tracker. Triggers include "end session", "session end", "close the session", "wrap up", "we're done for today".
---

# Session End

Close the active session file so another developer or agent can understand everything that
happened without reading it top to bottom.

## Step 0: Resolve locations

```bash
eval "$(bash "${CLAUDE_PLUGIN_ROOT}/skills/session-start/scripts/locations.sh")"
echo "$SESSIONS_DIR | $SPECS_DIR | $LOC_SOURCE"
```

Order: `.agent-ops.json` → `COS_SESSIONS_DIR`/`COS_SPECS_DIR` in the agent-ops config →
`./sessions`, `./specs`. Details: [locations](../session-start/references/locations.md).

## Step 1: Find the session

Read `$CURRENT_SESSION`. Match the `[tag]` to the current work or `$ARGUMENTS`; ambiguous →
list and ask inline. No tracker or no active session → say there is nothing to end and
suggest `/agent-ops:session-start`. Stop.

## Step 2: Append the closing summary

`## Session Summary` with:

- Duration (first update to now, from real timestamps)
- **Git**: files added/modified/deleted with change type, commits made, final `git status`
- **Todos**: completed vs remaining, both listed
- Accomplishments and features implemented
- Problems hit and their solutions; breaking changes and important findings
- Dependencies and configuration changed; deployment steps taken
- Lessons learned (format: [update format](../session-update/references/update-format.md))
- What was not completed, and tips for whoever picks it up

## Step 3: Propagate durable knowledge

- Fold durable lessons and standards into the repo's `CLAUDE.md` and standards docs under `$SPECS_DIR`.
- Refresh `## Context Documents` with the files that would get a new agent up to speed fastest.

## Step 4: Close the tracker

- Frontmatter: `status: completed` (or `blocked` / `paused`), refresh `last_updated`.
- Remove **only this session's line** from `$CURRENT_SESSION`; never clear the file.

## Step 5: Confirm

One line: path closed and final status.
