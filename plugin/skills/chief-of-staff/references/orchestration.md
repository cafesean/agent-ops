# Orchestration — the chief's staff

Script paths: `$S` = `${CLAUDE_PLUGIN_ROOT}/skills/chief-of-staff/scripts`.

## Contents

- [Subagent or session?](#subagent-or-session)
- [Task file](#task-file)
- [Dispatch and the queue](#dispatch-and-the-queue)
- [Worker lifecycle](#worker-lifecycle)
- [Continuation](#continuation)
- [The plan — next.sh, per machine](#the-plan--nextsh-per-machine)
- [Heartbeats and check-ins](#heartbeats-and-check-ins)
- [Asks — the Needs-you lane](#asks--the-needs-you-lane)
- [DEPLOY-LOCK](#deploy-lock)
- [Prod release = switches ON](#prod-release--switches-on)
- [Ship tracking (add-on)](#ship-tracking-add-on)
- [Goal gate](#goal-gate)
- [Charter template](#charter-template)
- [Rules](#rules)

## Subagent or session?
| Use | When |
|---|---|
| Agent tool subagent (routed `model`) | Short, bounded, result needed in this turn. Default. |
| Worker session (`spawn.sh`) | Long work (> 30 min), must outlive this session, or the user may watch/steer it |

## Task file
`tasks/<name>.md` is the ONE coordination file per worker: frontmatter (strict YAML subset, parsed stdlib-only by `scripts/lib/tasks.py`) + the charter as body + report lines under `## Reports`.

```yaml
---
name: w-export-2                 # = Claude -n name = pane/window title
to: w                            # machine prefix that runs it (COS_MACHINE_PREFIX)
from: chief                      # who queued it (user, chief, a worker)
parent_goal: G4                  # `### G4 · ` heading in GOALS.md
status: open                     # open | claimed | running | done | failed | parked | stopped
model: <model name>
approved: true                   # false = one-way door awaiting the user → the queue refuses it
needs: []                        # optional capability gates (e.g. vault, when that add-on is on)
dir: <repo-root>                 # one of $COS_LAUNCH_DIRS
agent:                           # optional plugin:agent
where:                           # stamped by spawn.sh
task_goal: "<one sentence — the outcome THIS task delivers>"
done_means: "<the concrete check>"
created: 2026-01-01
started:
closed:                          # stamped by stop.sh
ticket: PROJ-88                  # optional, if you use a tracker
heartbeat_min: 60
depends_on_missions: []          # tasks that must be done first
story_list: <path>/story_list.json   # optional: N/M done + next pending story
light: false
asks: []                         # block list — see Asks
decisions: []
slices: []                       # optional: id, title, status, owner, depends_on, story_list
---
<charter body — template below>

## Reports
status: WORKING 2026-01-01 10:12 [G4] export … ticket: PROJ-88 In Progress
```
Rules: top-level `key: value`, flow lists `[a, b]`, block lists of flat maps (`asks:`, `slices:`) or scalars (`decisions:`); quote values holding `: ` or `#`. Workers only append to `## Reports` and add items to `asks:`, never edit other keys. CLI: `tasks.py get|set|report|json|list|new`.
- **Parse traps:** scalars placed after `asks:` land inside the list; `\$` in a double-quoted string is an invalid escape. Keep top-level scalars above `asks:`, write `$` plainly. After any edit that smells wrong, run `python3 scripts/lib/tasks.py` on the file: a parse failure silently hides that worker's asks.

## Dispatch and the queue
1. **Write the task**: `python3 $S/lib/tasks.py new tasks/<name>.md --name N --to <prefix> --from <who> --charter <draft>` (or by hand).
2. **Start now**: `$S/spawn.sh --task-file tasks/<name>.md [--continues OLD] [--agent X] [--light] [--force] [--dry-run] [--no-goal]` (flags override frontmatter). `to:` must be this machine's prefix and status `open|claimed`.
3. **Or queue it**: leave `status: open`. `queue-run.sh` (from `next.sh`, from SWEEP) takes open tasks with `to:` = this machine, refuses `approved: false` and unmet `needs:` (each refusal printed once), claims by rename (only one process wins), runs `spawn.sh --task-file`. A failed spawn goes back to `open` with the exit code. `--max N` (default 2), `--dry-run`.
4. **Another machine**: write the task with `to: <its prefix>`, status open; its own sweep picks it up.

spawn.sh gates: `task goal:` missing or parent missing/unknown/parked → exit 2 (`--no-goal` overrides, PARK risk); `--dir` not in `$COS_LAUNCH_DIRS` → exit 2; bad name → exit 2; foreign prefix → refused; load `OFFLOAD` → exit 3 unless `--light`/`--force`. The launcher (`COS_LAUNCHER=tmux|cmux|print`) decides where the worker opens; `print` prints the exact `claude` command for the user to run. The launch script exports `COS_WORKER`, `COS_TAG`, `COS_REPORT_FILE`, `COS_HEARTBEAT_DIR` for the hooks.

`OFFLOAD` with no build workers running: check `ps -Ao pcpu,command -r | head`. Load from OS daemons, not builds → `--force` is fine for a worker with a deadline.

## Worker lifecycle
1. **Task** → `tasks/<name>.md`.
2. **Spawn** → by hand or by the queue; status `running`, `started:` stamped, `status: STARTED` report line.
3. **Run** → the worker appends a report at each milestone and at the end.
4. **Collect** → `collect.sh` every sweep. Report values: `STARTED`, `WORKING`, `BLOCKED`, `DONE`, `FAILED`.
5. **Verify** → on DONE, check the artifact (commit hash, test output, file). Unverified DONE stays running.
6. **Close** → `stop.sh <name> DONE|FAILED|STOPPED [--force] [--dry-run]`. Refuses: no `session:` since STARTED (exit 4); an open ask unless `parked` (exit 5); a foreign prefix (exit 6); DONE without `session:` + `teardown:` — plus `refs:` when `COS_REQUIRE_REFS=1`, `shipped:` when ship tracking (`COS_SHIPPED`) is on and code moved, `jira:` when Jira is configured (exit 7). Kills only its own pid and pane, never the chief or the user's sessions.
   - Refused DONE: confirm the artifact with live git, fill the gap yourself, record leftovers in STATE.md → Owed, then `--force`.
7. **Archive** → `archive.sh` daily: tasks closed > 24 h → `_archive/` read-only; briefs beyond the newest 3 → `_archive/briefs/`. Never deletes.
8. **State** → STATE.md lines change in the same turn as the landing (in place).

## Continuation
A successor of any earlier worker (died, usage-limited, context-full, or a planned `-N` step) is ALWAYS spawned with `--continues <old>`. **Session file first**: the last `session:` path in the old task's `## Reports` (else frontmatter `handoff:`). **Current** = the file exists and no real-work report came after the line that named it. Current → FIRST STEP = read it (Resume Here) → reconcile git in every repo → one report line. Not current → the newest transcript `~/.claude/projects/<launch-dir slug>/*.jsonl` holding the old name; FIRST STEP = mine it with a cheap-model subagent (`/agent-ops:session-from-transcript`) into a Resume Here. Neither → exit 2. The new task records `continues:`; the old one becomes `status: stopped` + `handoff: "superseded by <new>"`.

**Resume the SAME session** only with `spawn.sh --resume <session-uuid> --task-file tasks/<name>.md`: same model, effort, flags and agent as the spawn, no first prompt, so the prompt cache survives. A bare `claude --resume` can change model or flags and re-read the whole context. Live process → exit 2 (stop it first).

## The plan — next.sh, per machine
`next.sh` (on a schedule, and on demand) runs `queue-run.sh` (`--no-queue` skips), then plans ONLY this machine's tasks into ITS block `<!-- cos:next:<prefix> -->` of Outstanding.md. `outstanding.sh` keeps every block. Each run stamps `- <prefix> next.sh: …` under STATE.md → *Last verified*. `--alert` prints only tasks that newly flipped to blocked/died and new asks (for a notifier, if configured).

Per task: **Now** = latest report + story count · **Next** = next pending story or slice · **Blocked by** = BLOCKED report, unmet `depends_on`, open ask, 💀 died (running, no live pid), stale reports. Sections: ⛔ Needs you · Queue · 🧹 Stale state · workers.

**🧹 Stale state** flags: tasks running whose report says DONE; rows quiet ≥ 1 day with no live pid; asks open > 1 day; goals still `confirm?`; the same ONE Thing 3 briefs in a row or its parent goal `done`. SWEEP closes them or asks.

## Heartbeats and check-ins
Zero tokens until needed.
- The heartbeat hook (PostToolUse + Stop) touches `$COS_DIR/.heartbeat/<worker>` for any session with `COS_WORKER` set.
- `checkin.sh` (cron `13,43` + every SWEEP) sends `⟦CK⟧` only to this machine's workers with a live pid, silent > 30 min and idle ≤ 1 h. Idle > 1 h is never pinged (cold cache).
- The check-in hook (UserPromptSubmit): the exact prompt `⟦CK⟧` injects `protocols/ck.md`: one report line `did · now · next · blocks`, then reply `ok`.
- Hooks arm only in sessions started after the plugin update. Never restart live sessions for it.

## Asks — the Needs-you lane
One list for the user: every open ask from every task, at the top of each machine's `cos:next` block. The worker adds the ask to its task `asks:` and names it in a report line; the worker or chief closes it when answered and moves the answer to `decisions:`.
```yaml
asks:
  - id: a1
    class: TEST                         # TEST (user runs something) | DECIDE (pick an option) | APPROVE (OK a one-way door)
    what: "Retest the signup flow on a real phone"
    asked: 2026-01-01T13:43             # real clock (`date`), never guessed
    not_before: 2026-01-01T13:55        # optional
    steps: "open app | sign up | confirm email"   # TEST only, ONE quoted string with " | "
    options: "A keep token | B replace"  # DECIDE only; first = recommended
    default_if_silent: "proceed with A at 18:00"   # DECIDE/APPROVE; empty = blocks
    status: open                        # open | answered | withdrawn
decisions:
  - "2026-01-01 11:08 hotfix: HOLD until the auth change ships (user)"
```
Rendered TEST → APPROVE → DECIDE, oldest first.
- **Park rule**: an ask waiting > `$COS_PARK_MIN` min (default 50) shows `💤 park it`: the worker writes its handoff, sets `status: parked`, stops. A resume within 60 min is still cache-warm.
- **Never stop a worker with an open ask** to meet a cap; park it. `stop.sh` exit 5 enforces it.
- Check the charter's *Pre-authorized* list before asking; those never become asks.
- **A broad answer covers only what the user was shown.** "go on all" applies only to the numbered asks just shown, each read as its narrowest option. In the next reply, state the exact write or deploy the go was read as.

## DEPLOY-LOCK
Rows in STATE.md `## DEPLOY-LOCK`: `| repo · env | held by | since | why / release when |`.
- Before promoting any repo to main/prod: add a row. Remove it when prod is verified.
- Another holder on that repo · env → wait, and report it.
- Promoting a shared branch ships EVERY commit on it: name the commits riding along that are not yours and get their owner's OK first.
- With 2+ builders live, one release-owner session holds these rows, merges the shared branches, numbers migrations and deploys. Builders push their integration branch and send it `release-request: <repo> <branch@hash> <migrations> <switches> <proof>`.

## Prod release = switches ON
A release that merges code but leaves its switches off is NOT done.
- **Default = parity with dev.** Every switch ON in dev for the shipped features goes ON in prod in the SAME release: env vars, feature flags, config rows, seeds, allow-lists.
- **Report shape:** `feature | dev | prod before | prod after | proof`, each ON proven by behaviour (a run, a call, a page), not by an env list.
- **Never say "live in prod"** until every layer is live: code, workers, migrations, env/flags, config. Name the layer that is not.
- Money, messages to real customers, and another team's live systems wait for the user's separate word.
- **Chief:** reject a prod-release DONE without the switch table; send it back.

## Ship tracking (add-on)
When enabled, workers append each shipped item to `$COS_SHIPPED` (`shipped.yaml`: id, plain-words title, ticket, worker, date, repos → branch + work commits) and report `shipped: <id>` on DONE. `scripts/addons/where-it-is.sh` reads it and reports each item as local / pushed / dev / prod from live git, gaps first, with a checked time; `scripts/addons/release-gap.sh` lists, per repo in `$COS_RELEASE_REPOS`, what is on the dev branch but not on prod. Answer "where is X" and "what's left to release" from these, never from STATE.md or a worker's say-so.

## Goal gate
- Every task gets its OWN task goal; the broad GOALS.md goal is its parent.
- `task goal:` = one sentence, an outcome not an activity, in the user's words where they gave them. `done means:` = the concrete check. `parent goal:` = an ID with a `### <ID> · ` heading in GOALS.md.
- spawn.sh injects task goal, done-means, parent outcome + intent and the off-goal rule into the first prompt; every report line is tagged `[<parent ID>] <task slug>`.
- `intent:` comes from the user or the parent goal, never paraphrased or invented.

## Charter template
```markdown
# Charter: <name>
task goal: <one sentence — the outcome THIS task delivers>
done means: <the concrete check: real run / commit on branch X / test count>
parent goal: <ID from GOALS.md>
intent: <why it matters — the user's words, or copied from the parent goal>
off-goal rule: if the next step doesn't serve the TASK goal, report BLOCKED off-goal instead. Tag every report line [<ID>] <task slug>.

Task: <one paragraph, outcome not steps>
Read first: <paths>
Stop and report BLOCKED if: <conditions>
Never (one-way doors): prod deploys, main pushes, writes to prod/shared/remote DBs, messages to anyone but the user, spending money, deleting branches/data.
DEPLOY-LOCK: before promoting any repo to main/prod, add a row to STATE.md `## DEPLOY-LOCK`; remove it when prod is verified; another holder → wait and report.
Teardown at DONE: stop your servers, remove the clean worktrees you made (no --force), keep branches, report `teardown: N removed, M kept (why)`.

## Pre-authorized (no need to ask)
- Read-only queries on shared DBs inside a read-only transaction or role
- Creating/updating tracker cards for this task (no deletes)
- Dev deploys of scope already approved in this task; prod stays gated
- Two-way-door defaults: file an APPROVE ask with default_if_silent, then continue
Still ask: prod deploys, prod/shared DB writes, main pushes, messages to anyone but the user, money, deletes.
<strike or add lines per task>

## Asking the user
Add an item to `asks:` in this file's frontmatter (id, class, what, asked from `date`, steps or options, default_if_silent, status: open). Name it in a report line. Waiting > 50 min → write your handoff, set `status: parked`, stop. Never edit other frontmatter keys.
Your own subagents: always pass `model`; cheaper model for read-only lookup, strongest for build/review/judgement.
Session log: run `/agent-ops:session-update` only when the whole task is finished, never mid-task; put its path in your report (`session:`).

## Reports — the ONLY channel back
Append under `## Reports` of this file. Plain text in your pane never reaches the chief.
    status: <WORKING|BLOCKED|DONE|FAILED> <YYYY-MM-DD HH:MM> [<parent ID>] <task slug> …
    - did: <one line>
    - evidence: <hash / test count / path>
    - where: <local | pushed <hash> | dev <evidence> | prod <evidence>>   (required on DONE when a change shipped)
    - next: <one line, or the question for the user with your default>
    - session: <session file path>          (required on DONE)
    - teardown: <N removed, M kept (why)>   (required on DONE)
    - refs: <docs updated, or none>         (required on DONE when COS_REQUIRE_REFS=1)
    - shipped: <id>                         (required on DONE when ship tracking is on and code moved)
Report at every milestone and at the end.
```

## Rules
- WIP ≤ 3 workers per goal; fill free slots, never leave one idle while DRIVE items wait.
- Workers never ask the user in the pane alone; every ask goes into `asks:` plus a report line.
- A live pid with quiet reports is slow, not dead. Never spawn a duplicate for the same task.
- Worker idle > 1 h: don't re-message it. Stop it and spawn a successor with `--continues`.
- Two workers never share a git working tree: a worktree per worker.
- Multi-lane work: one `integration/<slug>` branch per repo; lanes merge into it; it merges to the shared branch once per batch, then one proof run.
- The chief is a session and dies too. Its successor reads STATE.md then Outstanding.md; the handoff lists only *Arm on start* steps.
