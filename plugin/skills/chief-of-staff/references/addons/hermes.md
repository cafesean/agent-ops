# Add-on: scheduler agent — the jobs the chief only watches

Optional. Use when a separate always-on scheduler agent (for example Hermes, an agent harness with its own cron and chat delivery) runs the headless jobs. Off when its config is empty: the scripts print `addon hermes not configured, skipping`.

Scripts: `${CLAUDE_PLUGIN_ROOT}/skills/chief-of-staff/scripts/addons/hermes-jobs.sh`, `hermes-sweep.sh`.

## What the scheduler owns
| Job | Typical schedule | Runs | Does |
|---|---|---|---|
| Stand-up brief | `0 8,13,18 * * *` | `hermes-sweep.sh brief` | Writes the BRIEF to `briefs/` and the user's chat channel |
| Plan daemon (no LLM) | `*/20 * * * *` | `next.sh --alert` → `queue-run.sh` | Spawns open tasks for this machine, rewrites its `cos:next` block, stamps STATE.md; notifies only on a NEW blocked / died / ask |
| Dead-man | with the morning run | reads `$COS_DIR/_heartbeat` | "chief is down" when no SWEEP has stamped it (`../autonomy.md` → *Dead-man*) |

Trust the scheduler's own job list over this table.

## What the chief does — watch only
- `hermes-jobs.sh` (table) · `--flags` (in BRIEF) · `--new` (in SWEEP). New flag on a money or legal job = FIRE; any other flag → the next brief's Blockers.
- Never edit, pause, resume, delete or create a scheduler job from the chief. A job that needs building or fixing is the user's call.
- If the scheduler runs its agent steps on a different CLI, keep it that way; don't put `claude -p` into its jobs unless the user set it up so.
- Notifications between briefs only for a new FIRE or a new blocker on the user, to `$COS_TELEGRAM_TARGET` or whatever channel is configured.

## Machines without the scheduler
Their chief session's own SWEEP cron runs `queue-run.sh` and `next.sh` when its block is stale, and `checkin.sh` from its `13,43` cron. No chief alive there → that machine's tasks stay `open` until one starts (no machine claims a foreign prefix).
