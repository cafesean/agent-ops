# Coming from claude-mem-pro

If you used claude-mem-pro, these commands and skills now also exist here as `/agent-ops:<name>`:

| claude-mem-pro | agent-ops |
|---|---|
| `/claude-mem-pro:session-start` | `/agent-ops:session-start` |
| `/claude-mem-pro:session-update` | `/agent-ops:session-update` |
| `/claude-mem-pro:session-end` | `/agent-ops:session-end` |
| `/claude-mem-pro:version-bump` | `/agent-ops:version-bump` |

Session files keep the same format (frontmatter + sections), so existing files keep working.

## Where files go
`.agent-ops.json` in the repo (`sessionsDir`, `specsDir`) → `COS_SESSIONS_DIR` / `COS_SPECS_DIR` in
`~/.claude/agent-ops/config.env` → the repo's existing `_ai/sessions` folder (and `_context` when `specs/` does not exist) → `./sessions` and `./specs` in the repo root. claude-mem-pro's recorded paths are not read:
if your archive lives elsewhere, set `sessionsDir` in `.agent-ops.json` so nothing moves.
