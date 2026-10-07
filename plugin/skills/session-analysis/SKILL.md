---
name: session-analysis
description: Use when mining curated session files (the .md logs written by session-start / session-update) for knowledge to update Claude Code agents, skills, CLAUDE.md or standards docs. Triggers include "analyze sessions", "extract from sessions", "session knowledge", "what changed recently", "session lessons", "update the skills from recent sessions".
---

# Session Analysis for Plugin Updates

Turn recent session files into concrete updates for agents, skills and project docs.
Source is the curated `.md` session files — for raw `.jsonl` transcripts use
`/agent-ops:recap-session` or `/agent-ops:session-from-transcript`.

## Step 0: Resolve locations

```bash
eval "$(bash "${CLAUDE_PLUGIN_ROOT}/skills/session-start/scripts/locations.sh")"
echo "$SESSIONS_DIR | $SPECS_DIR | $LOC_SOURCE"
```

Order: `.agent-ops.json` → `COS_SESSIONS_DIR`/`COS_SPECS_DIR` in the agent-ops config →
`./sessions`, `./specs`. Details: [locations](../session-start/references/locations.md).

## What to extract

Files are `YYYY-MM-DD-[tag]-description.md` with the frontmatter in
[file format](../session-start/references/file-format.md).

| Section | Extract | Maps to |
|---|---|---|
| Objective / summary | New feature areas, capabilities | Skill descriptions, agent examples |
| Update blocks (files, commits) | New files, modules, structural changes | Architecture sections, file paths in skills |
| Implementation details | Patterns, API shapes, component designs | Skill body, code patterns |
| Context Documents | Key paths, sources of truth | Reference sections |
| Lessons Learned / Architecture Issues / Decisions | Gotchas, rules, decisions | Critical rules, agent prompts |
| User Steering & Corrections | Where the agent went wrong | Rules that prevent the repeat |

## Process

1. **Filter** — by tag and date: `ls "$SESSIONS_DIR" | grep -F '[web]' | grep '^2026-05-'`; or by frontmatter `topics:` / `apps_touched:`.
2. **Inventory each session** — new features, new patterns and anti-patterns, new file paths, critical lessons (anything marked CRITICAL / confirmed), new example requests.
3. **Gap analysis** — for each item: an existing skill covers the area? → it mentions this item? no-op : update it. No skill? → significant enough for its own skill : add to the nearest one.
4. **Prioritise** — critical lessons first (prevent bugs), then new feature areas, stale paths, new trigger examples, structural docs.
5. **Write the updates**, then run the quality checks.

Templates (feature / bug fix / refactor), quality checks and cross-session rules:
[templates](references/templates.md).

## Rules

- Verify every file path still exists before writing it into a skill — sessions age.
- A lesson seen in two sessions is critical: flag it prominently.
- When sessions disagree, the later one wins (check git history if unsure).
- Include the why with every rule, and code where a pattern needs it.
