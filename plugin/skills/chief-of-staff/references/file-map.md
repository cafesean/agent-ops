# File map — what lives where

`$COS_DIR` = the state dir (default `$HOME/agent-ops/state`; set in config.env). Share it between machines if you want (a synced folder or a git repo); dot files and dot folders stay per machine. Each machine has its own prefix (`COS_MACHINE_PREFIX`), runs its own chief and `queue-run.sh`, and spawns only tasks addressed `to: <its prefix>`; the shared folder is the only link between machines (no ssh, no remote launch).

## In the state dir — the coordination things
| What | Where | Who writes | Who reads | Which machine |
|---|---|---|---|---|
| Task (charter + frontmatter + `## Reports`) | `$COS_DIR/tasks/<name>.md` | Anyone queues one (user, chief, a worker); `queue-run`/`spawn`/`stop` stamp status; the worker appends reports and `asks:` only | `collect.sh`, `next.sh`, `queue-run.sh` on the addressed machine, the user | Spawned, stopped and planned only by the machine whose prefix is in `to:` |
| Goals | `$COS_DIR/GOALS.md` | User (intent, status); chief (`- tracked:` bullets, `confirm?` goals) | spawn.sh goal gate, BRIEF, `next.sh` | any |
| What is true now (≤ 60 lines) | `$COS_DIR/STATE.md` | Chief SWEEP (its own `- <prefix>:` line, *Live crons*, Owed, Decisions); `next.sh` stamps; DEPLOY-LOCK rows by whoever promotes | Every brief, sweep and new chief, FIRST | each edits only its own lines |
| The one list the user watches | `$COS_OUTSTANDING` (default `$COS_DIR/Outstanding.md`) | `outstanding.sh` (whole note); each machine's `next.sh` only its `<!-- cos:next:<prefix> -->` block | user, chief | own block only |

## In the state dir — not coordination
| What | Where | Who writes | Who reads |
|---|---|---|---|
| Briefs (newest 3) | `$COS_DIR/briefs/` | Chief BRIEF (or a headless brief add-on) | `outstanding.sh`, brief check |
| History | `$COS_DIR/_archive/` | `archive.sh` only; read-only after, never deleted | `--continues`, audits |
| Dead-man stamp | `$COS_DIR/_heartbeat` | every chief SWEEP (`touch`) | any dead-man check |
| Worker heartbeats | `$COS_DIR/.heartbeat/<worker>` | heartbeat hook | `checkin.sh` (per machine) |
| Alert dedupe | `$COS_DIR/.next-alert-state.json` | `next.sh --alert` | `next.sh --alert` (per machine) |
| User layer | `$COS_USER_DIR` (default `$COS_DIR/user`): `rules.md`, `bin/`, `README.md` | the user (init makes the skeleton); the chief adds a standing rule to `rules.md` the same turn | the chief after STATE.md; every worker in turn 1 (spawn.sh line); config keys that point at `bin/` scripts |
| Chief name | `$COS_DIR/CHIEF` | the chief at Step 0 / takeover | workers before messaging the chief; spawn.sh role pick |
| Release owner name (optional) | `$COS_DIR/CAPTAIN` | the release owner session | builders sending release requests |
| Domain leads (optional) | `$COS_DIR/LEADS`, `teams/<domain>.md` | the chief; each lead its roster | workers, `reap.sh` (leads are never reaped) |
| Steering files | `$COS_DIR/steering/<name>.md` | `steering-export.py` (spawn `--continues`, stop `HANDOFF`, context-handoff guard) | the successor |
| Load state | per machine, beside the config (`lib/loadgate.py`) | `load-check.sh` | agent-budget-guard hook |
| Worktree owner stamps | under `.heartbeat/` (per machine) | worktree-owner hook | `stop.sh` exit 9 |

## In the plugin (git, not the state dir)
| What | Where | Read by |
|---|---|---|
| `⟦CK⟧` protocol | `skills/chief-of-staff/protocols/ck.md` | the check-in hook, fresh on every ping |
| Worker rulebook | `skills/chief-of-staff/references/worker-rules.md` | every worker (spawn.sh puts one pointer per section in its prompt) |
| Scripts | `scripts/*.sh`, `asks.py`, `ctx.py`, `steering-export.py`, `reap.sh`; `scripts/lib/` (`tasks.py`, `cos-os.sh`, `lastturn.py`, `loadgate.py`, `handoff.py`) | the chief, hooks, schedulers |
| Hooks | `plugin/hooks/`: heartbeat, check-in, heavy-cap-guard, agent-budget-guard, send-cold-guard, cold-cache-warn, worktree-owner, context-handoff-guard, ask-guard, cos-reap, agent-rule, agent-refusal-warn | Claude Code, per session |
| Scripts, hooks, this skill | the installed plugin (`${CLAUDE_PLUGIN_ROOT}`) | everything |

## NOT in the state dir — and why
| What | Where | Why outside |
|---|---|---|
| Local config | `${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}` | Paths and prefix differ per machine; may name notifier commands. Never synced, never in git. State and the user layer may sit in ONE synced folder all machines share |
| Worker launch scripts | written by spawn.sh under the local config dir | Per machine; kept out of shared folders |
| Secrets | your secret store (a user-layer script may front it) | Secrets never sit in a folder agents read freely |
| Transcripts | `~/.claude/projects/<slug>/*.jsonl` | Machine-local by design; why a session file comes first for a successor |
