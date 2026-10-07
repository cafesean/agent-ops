# Sources of truth

Rule: answer each question from its canonical source. If two sources disagree, the canonical one wins and the other gets fixed in the same sitting.

## Core (always present)
| Question | Canonical source | How to read |
|---|---|---|
| What is true now for the chief (last verified per machine, live crons, DEPLOY-LOCK, owed by the user, decisions) | `$COS_DIR/STATE.md` | Read FIRST, every brief/sweep/new session |
| The plan: needs-you asks, queue, stale state, workers | `$COS_OUTSTANDING` → this machine's `cos:next` block | Read second; `next.sh` refreshes it |
| Workers the chief runs | `$COS_DIR/tasks/<name>.md` (frontmatter + `## Reports`) | `collect.sh` |
| Goals, the user's words, tracked items | `$COS_DIR/GOALS.md` | `goals.md` |
| Past state, closed tasks, old briefs | `$COS_DIR/_archive/` | read-only |
| Live sessions | `~/.claude/sessions/` | `sessions.sh` |
| What shipped where | live git (`git log`, `git branch -r --contains`) | never from memory or a worker's say-so |
| Is feature X built | the code, confirmed by running it | never from memory alone |

## Optional (point the chief at yours in config.env or STATE.md)
| Question | Typical source |
|---|---|
| Project state for a repo | that repo's `STATE.md` / `CLAUDE.md` (`$COS_MONOREPO`, `$COS_REPO_PATHS`) |
| What happened in a sitting | the repo's session logs (`/agent-ops:session-update`, dir `COS_SESSIONS_DIR`), if you keep them |
| Why a decision was made | specs / ADRs in the repo |
| Ticket status | your issue tracker (`$COS_JIRA_BASE`), trusted only where evidence is cited |
| Servers, hosts | an inventory file (`$COS_INVENTORY`); key names only, never paste values |
| Standing rules and traps | your memory dir (`$COS_MEMORY_DIR`) |
| Personal tasks, due dates | your reminders or todo app |
| Ship status per item (add-on) | `$COS_SHIPPED` via `scripts/addons/where-it-is.sh` |

## Traps
- A CLI proxy or wrapper around `git` or `grep` can return filtered or fabricated output; use `command git` / `command grep` when it matters.
- An idle notice is not proof of done; read the artifact.
- Notes about schedules go stale; read the scheduler's own list.

## Write-back duty
When the chief changes a verdict (something landed, a goal moved), it updates the canonical source the same turn: STATE.md (replace lines in place), the task file, then any project STATE file or tracker. Never leave a finding written but not applied.
