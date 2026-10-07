# File map — what lives where

`$COS_DIR` = the state dir (default `$HOME/agent-ops/state`; set in config.env). Share it between machines if you want (a synced folder or a git repo); dot files and dot folders stay per machine. Each machine has its own prefix (`COS_MACHINE_PREFIX`).

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
| Shipped items (add-on) | `$COS_SHIPPED` (`shipped.yaml`) | worker on DONE when code moved; chief fills a gap | `where-it-is.sh`, `outstanding.sh` |
| Account limits (add-on) | `$COS_DIR/accounts.md` | `account-limit.sh` | `spawn.sh --account auto` |

## In the plugin (git, not the state dir)
| What | Where | Read by |
|---|---|---|
| `⟦CK⟧` protocol | `skills/chief-of-staff/protocols/ck.md` | the check-in hook, fresh on every ping |
| Scripts, hooks, this skill | the installed plugin (`${CLAUDE_PLUGIN_ROOT}`) | everything |

## NOT in the state dir — and why
| What | Where | Why outside |
|---|---|---|
| Local config | `${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}` | Paths and prefix differ per machine; may hold notifier targets. Never synced, never in git |
| Worker launch scripts | written by spawn.sh under the local config dir | Per machine; kept out of shared folders |
| Secrets | your secret store or vault add-on (`addons/secrets.md`) | Secrets never sit in a folder agents read freely |
| Claude account tokens (add-on) | OS keychain, by id | Only the id is written anywhere (`addons/accounts.md`) |
| Transcripts | `~/.claude/projects/<slug>/*.jsonl` | Machine-local by design; why a session file comes first for a successor |
