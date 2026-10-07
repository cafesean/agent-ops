# Autonomy — wake up, drive, conduct

The chief does not wait for instructions. It wakes on a schedule, reads the world, moves the work, and only interrupts the user for one-way doors.

## Wake mechanisms
| Mechanism | How | Use for |
|---|---|---|
| Resident chief session | A long-lived session per machine (e.g. `<prefix>-chief`) with two session crons armed by SKILL.md Step 0 on every invoke (idempotent via `CronList`): SWEEP `7,27,47 * * * *` and checkin `13,43 * * * *` (`scripts/checkin.sh`) | Working hours; keeps workers moving; cheapest because context stays warm |
| Plan daemon (no LLM) | Any scheduler (cron, launchd, systemd timer) running `scripts/next.sh --alert` every ~20 min | Runs `queue-run.sh` and keeps this machine's `cos:next` block current even when no Claude session is alive. Empty stdout = nothing new |
| Headless brief / dead-man (add-on) | A scheduler agent runs the brief and checks the dead-man stamp | Briefs when no session is open — `addons/hermes.md` |

Creating or changing a system-level schedule is the user's call: propose it, don't arm it silently. Proof the daemon fires: the `- <prefix> next.sh:` line under STATE.md → *Last verified* moves on schedule.

## The drive loop (each wake)
1. Read: `$COS_DIR/STATE.md` first, then this machine's `cos:next` block in Outstanding.md, then `queue-run.sh`, `checkin.sh`, `collect.sh`, `sessions.sh`, `load-check.sh`, and the other sources in `sources-of-truth.md`.
2. Close finished work: verify artifacts, `stop.sh NAME DONE`, update STATE.md lines in place + canonical sources the moment it lands. Close 🧹 stale rows. Once a day `archive.sh`.
3. Unblock: answer worker BLOCKED items the chief can decide (two-way doors, on the charter's defaults).
4. Fill slots: dispatch the next DRIVE item for each goal up to WIP 3.
5. Tell the user only what changed for them, in the status-reply format (SKILL.md → *Status replies*). Nothing changed → header + table still; no workers either → `noop`.
6. LEARN.

## May do unattended
- Read anything; run read-only commands.
- Spawn, collect, stop its own workers (this machine's prefix only); write tasks for another machine.
- Local branches, commits on feature branches in worktrees, local tests.
- Write to its state dir (`tasks/`, `STATE.md`, `GOALS.md` tracked bullets, briefs), run `archive.sh`.
- Post to its own notification channel, if configured.

## Never unattended — ask the user
- Push to or merge into shared branches, deploy, run migrations.
- Writes to shared/remote DBs.
- Messages to anyone other than the user.
- Money, contracts, anything legal.
- Killing processes it did not start; changing crons or loops the user armed.
- Deleting branches or data.

## Session-only schedules die with the session
A `/loop` or session cron lives only as long as the chief session. Record every one in STATE.md → *Live crons* (id, schedule, expiry), replacing the row. A new chief session re-arms them from the handoff's *Arm on start* list and writes the new ids back. SWEEP and checkin are the exception: Step 0 re-arms them on invoke.

## Dead-man
Each sweep stamps `$COS_DIR/_heartbeat`. Anything outside the chief (a scheduler job, a cron) can check it: older than 3 h during working hours → notify "chief is down, last sweep <time>".
