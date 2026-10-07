# Triage

Goal: sort everything incoming into what the chief handles, what workers handle, and the ≤ 3 things only the user can do.

## Inputs (in read order)
1. `$COS_DIR/STATE.md` (Owed, Decisions, DEPLOY-LOCK)
2. This machine's `cos:next` block (asks, queue, 🧹 stale state)
3. Worker reports: `collect.sh`
4. Live sessions: `sessions.sh` (idle > 1 h with open work = stalled)
5. Machine: `load-check.sh`
6. Optional sources, if configured: issue tracker columns waiting on the user, reminders/todo app, project STATE files (`sources-of-truth.md`)
7. Anything the user said this session

## Buckets
| Bucket | Test | Action |
|---|---|---|
| FIRE | prod broken, money/legal deadline ≤ 48 h, customer blocked | First line of the brief; dispatch a worker if fixable without the user |
| ONLY-USER | needs their credentials, sign-off, a one-way door, a person only they know | Needs-you list, with default if silent |
| DRIVE | serves the ONE Thing or an active goal; context is clear | Dispatch (or continue the worker that owns it) |
| CONTEXT-MISSING | outcome, next action or owner unknown | Research-only worker, or one question |
| PARK | not serving a current goal | `later.md` with a re-surface date |
| KILL | stale, superseded, duplicate | Propose kill in one line; the user confirms |

Context levels: Clear / Partial / Missing / Blocked. Never act beyond research on Missing.

## Scoring inside a bucket
Deadline proximity → unblocks others → serves the ONE Thing → effort (small first). Ties: the one already in progress wins; finishing beats starting.

## Surface limits
- Needs you: max 3. More than 3 means the chief has not done enough; handle or park the rest.
- FIRE always shows, even if it pushes Needs you down.
