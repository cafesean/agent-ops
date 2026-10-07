# Where session files and specs live

Every session-logging skill (`session-start`, `session-update`, `session-end`,
`session-from-transcript`, `session-analysis`) resolves two directories the same way.
Nothing is assumed about the repo layout, and no other plugin is required.

## Resolution order (first hit wins, per key)

| # | Source | Session files | Specs |
|---|--------|---------------|-------|
| 1 | `<repo>/.agent-ops.json` | `sessionsDir` | `specsDir` |
| 2 | agent-ops config (`$AGENT_OPS_CONFIG`, default `~/.claude/agent-ops/config.env`) | `COS_SESSIONS_DIR` | `COS_SPECS_DIR` |
| 3 | Default | `<repo>/sessions` | `<repo>/specs` |

Relative paths resolve against the repo root (`git rev-parse --show-toplevel`, else the
current directory). `~` and Windows paths (`C:\x`) are accepted.

Optional: if a memory plugin such as claude-mem-pro has already recorded a per-project
`sessionsDir` / `specsDirs` for this repo and none of rows 1-2 is set, you may use its
values instead of the defaults (keeps an existing session archive in place).

Active-session tracker: `<sessions dir>/.current-session` — one session filename per line,
so several sessions can be active at once. Append on start, remove only your own line on end.

## Step 0 (identical in every skill)

```bash
eval "$(bash "${CLAUDE_PLUGIN_ROOT}/skills/session-start/scripts/locations.sh")"
echo "$SESSIONS_DIR | $SPECS_DIR | $LOC_SOURCE"
```

The script only reads; it prints `REPO_ROOT`, `SESSIONS_DIR`, `SPECS_DIR`,
`CURRENT_SESSION` and `LOC_SOURCE`. Create `$SESSIONS_DIR` with `mkdir -p` only when you are
about to write a session file. If `$CLAUDE_PLUGIN_ROOT` is unset, apply the table by hand.

## Per-project override

```json
{ "sessionsDir": "docs/sessions", "specsDir": "docs/specs" }
```

Save as `.agent-ops.json` in the repo root (commit it if the team shares the layout).
Machine-wide defaults go in the agent-ops config, set by `/agent-ops:init`:

```bash
COS_SESSIONS_DIR="./sessions"
COS_SPECS_DIR="./specs"
```
