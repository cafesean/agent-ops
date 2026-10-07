# Worker prompt examples (opt-in)

`spawn.sh` gives every worker a short generic prompt: report protocol, concise output, the session log at the
end, teardown at DONE, and no secrets in tool output. Anything stricter is yours to add.

Add standing rules with `COS_WORKER_PROMPT_EXTRA` in `~/.claude/agent-ops/config.env`. Its text is put in
front of every new worker prompt (local and remote). Keep it to a few sentences: it is sent on every spawn.

```bash
COS_WORKER_PROMPT_EXTRA="<rule> <rule> <rule>"
```

Pick, edit or drop any of the examples below. Join the ones you want into one line.

## Time awareness
> TIME MATTERS: speed is part of done. Run independent pieces of work in parallel subagents, within the
> load-check limit. Batch tool calls. Don't re-verify what git or a passing test already proves. When
> blocked on the owner, wait idle and post one report line naming the ask. Post a status line at least
> every 30 minutes.

## No overdoing
> NO OVERDOING: before any new spec, build or test step, check whether it's already done (git log, session
> files, the task file). Re-run tests only if the diff since the last green run touches that code. Do only
> what the next step of the task goal needs: no speculative work beyond done-means. Unsure → ask in one
> report line.

## Test tiers
> TEST TIERS: a quick check (one proof for this change, a few minutes) is the default. Run a smoke test only
> when calling a deploy done. Run a full regression only for shared core code, auth/permissions, payments,
> data migrations or a release cut.

## Subagent time budgets
> SUBAGENTS: every subagent you dispatch gets a wall-clock budget (default 10 min, max 20) and the line
> "return partial at the budget". Subagents never wait on a deploy, CI run or lock; you own every wait.

## Needs-you banner
> NEEDS YOU: when a turn ends blocked on the owner, make the last line of your reply
> "NEEDS YOU: <ask in plain words, max 12 words>" (max 3 asks, recommended option first). Only when
> blocked. Still file the ask in your task file.

## Example
```bash
COS_WORKER_PROMPT_EXTRA="TEST TIERS: a quick check is the default; smoke only when calling a deploy done; full regression only for auth, payments, migrations or a release cut. NEEDS YOU: when a turn ends blocked on the owner, make the last line 'NEEDS YOU: <ask, max 12 words>'."
```
