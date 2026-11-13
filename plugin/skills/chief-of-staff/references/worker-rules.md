# Worker rules — how a chief worker works

The rulebook every spawned worker follows. spawn.sh puts one pointer line per section in the worker's first
prompt; the full rule lives here. Rules owned by another skill are linked, not copied. Opt-in extra lines for the
prompt itself: `worker-prompt-examples.md` (`COS_WORKER_PROMPT_EXTRA`).

## Contents
- [Roles](#roles)
- [Asks and the NEEDS YOU banner](#asks-and-the-needs-you-banner)
- [Autonomy — do it, don't ask](#autonomy--do-it-dont-ask)
- [Speed and heavy commands](#speed-and-heavy-commands)
- [No overdoing](#no-overdoing)
- [Test tiers](#test-tiers)
- [Subagents](#subagents)
- [KB first](#kb-first)
- [Issue tracker](#issue-tracker)
- [Messaging](#messaging)
- [Release and prod agents](#release-and-prod-agents)
- [Domain leads](#domain-leads)
- [Limits](#limits)
- [Secrets in files](#secrets-in-files)
- [Context size and handover](#context-size-and-handover)
- [Hook-blocked commands](#hook-blocked-commands)
- [Wind-down and teardown](#wind-down-and-teardown)

## Roles

spawn.sh picks the role, so each worker's prompt carries only the pointers that apply. Task frontmatter
`role: chief|builder|non-dev` overrides the pick.

| Role | Picked when | Gets |
|---|---|---|
| chief | name is the `$COS_DIR/CHIEF` file's name or matches `*-chief*` | every section except Release, Limits, Test tiers |
| builder | launch dir is under one of `COS_BUILDER_DIRS` (empty = every dir), or the session is the release owner | every section |
| non-dev | anything else (notes, finance, research) | every section except Release, Limits, Test tiers |

## Asks and the NEEDS YOU banner

- Every ask goes in the task file `asks:` block plus a report line. Format and lifecycle: `orchestration.md` → *Asks*.
  Check the charter's *Pre-authorized* list first: those need no ask.
- A small paid proof on dev inside a standing dev budget the user set runs without an ask; name the cost in the
  proof line. Prod spend, sends to real people and anything above budget still ask.
- Never use the `AskUserQuestion` tool in a worker pane: nobody watches it, the dialog blocks forever.
- Every ask carries a `check:` line (shell command, exit 0 = no longer needed) or an `evidence:` line. The
  ask-guard hook (`COS_ASK_GUARD`) denies an ask written without one.
- Print the banner as plain lines, never inside a code fence: tools that turn options into buttons only read plain text.
- Banner, when a turn ENDS blocked on the user (never for progress): the LAST lines of the reply are
  ```
  ████████████████████████████████████████████████████████
  ██  ⛔⛔⛔   NEEDS YOU   ⛔⛔⛔
  ██  1. <ask, plain words, ≤ 12 words> [<option> (rec) / <option>]
  ████████████████████████████████████████████████████████
  ```
  Max 3 asks, recommended option first and marked ` (rec)` on DECIDE/APPROVE asks (TEST asks need no mark).
  Asks with no fixed options (a command to run, a free answer) get no brackets. The literal text `NEEDS YOU`
  fires the Stop hook (sound, notification, pane mark).
- Show only asks verified THIS turn: `asks.py check <task file>`; done, answered or superseded →
  `asks.py close <file> <id> <reason>` and leave it out; still true → `asks.py verify <file> <id>`.
- Blocked on the user with nothing else to do: wait idle, one report line naming the ask. Waiting longer than
  `COS_PARK_MIN` (default 50 min) → park (handoff, `status: parked`).
- Never edit task frontmatter keys other than `asks:`.

## Autonomy — do it, don't ask

**Decide yourself, then report:** anything on dev; shipping a dev-proven fix of a bug the user reported, or a
security fix, through the release owner; prod config parity with dev; a small reversible prod data fix with backup
and undo; which page or option when evidence answers it.

**Yours to do, never an ask:** logging in to tools and consoles with the agent's own access, dashboard and console
settings, app configuration, feature switches, keys you can read from a console into the secret store. Only a step
that physically needs the user's hands (their passkey or second factor on their device, their phone) becomes an
ask, and it names every route you tried.

**Ask the user ONLY for:** money, spend or pricing; messages to real customers or the team; deleting data or
stores; legal text; secret rotation; design gates they asked for. Before filing any ask, re-read it: if your
access can do it, do it instead.

**Destroy is never inferred.** A delete, terminate or destroy runs only on the user's named go for that exact
resource (SKILL.md § Critical rules; `destroy-guard` hook). Report the facts, then ask.

## Speed and heavy commands

- Speed is part of done. Run independent stories in parallel lanes (subagents), up to the `load-check.sh` limit.
  Batch independent tool calls.
- **Independent work never waits on other work.** Build every repo of a change at once (deploy order still
  applies); the builder runs its own dev proof; type-check gates run side by side in separate worktrees; a release
  request goes out per item as each is green.
- Heavy commands (full suites, big type-checks, production builds) may be routed to another machine by a
  user-layer script; see your user rules (`$COS_USER_DIR/rules.md`). This machine at OFFLOAD, or the heavy-cap
  guard blocking a lane → use that route if your user rules name one, else wait for a slot. Keep local only what needs this machine: dev servers, local DB, tunnels,
  browser, `.env`.
- Foreground Bash that can pass 2 min: a long `timeout` or `run_in_background`. A long script runs under
  `nohup … > log 2>&1 &`, watched with a Monitor.
- Post a status line in the task file at least every 30 min: what finished, what runs next.

## No overdoing

1. Before any new spec, build or test step, check it is not already done: any ship-tracking script your user
   rules name, the issue tracker, git log, session files. A cheap subagent that reports in ≤ 5 lines.
2. Green stays green: re-run tests only if `git diff <last-green-hash>..HEAD` touches that code. Record the green
   hash in your report.
3. One right-sized proof per change. Exhaustive test matrices only for security or tenant-isolation stories.
4. Reviews stop when no P0/P1 findings are left; no extra rounds for minors. Don't re-verify what git or a passing
   test already proves. No lanes that only re-verify.
5. Do only what the next step of the task goal needs: no speculative lanes, no prep for steps the user hasn't
   taken, no generalising, no hardening beyond done-means. Unsure if needed → one report line, don't build it.
6. A spec number is the next number in THAT project's spec folder (per-project sequence, never global).

## Test tiers

| Tier | When | What |
|---|---|---|
| 1 quick check (DEFAULT) | every change | ONE proof for this change, run locally: one targeted test file or one real call/screen on your own local stack; type-check only the touched package. Never deploy to dev to try a change |
| 2 smoke | only when calling a deploy done | health check + touched pages + ONE happy path |
| 3 full regression (another machine when your user rules name one) | shared SDK/core, auth/permissions/tenant isolation, money, table-altering migrations, a prod release cut (once per cut), a bug that already regressed | full suite |

Unsure → Tier 1, and say so. Subagents follow the same tiers. A release request also needs the full-repo
type-check against the base error list (0 new): a check filtered to changed files misses a duplicate declaration
that breaks the build. Run base and head in ONE job and report `exit=<code> lines=<n> errors=<count>` per side
plus the error diff; a count of 0 with no exit code is not evidence.

Dev is the integration test. A change reaches dev only through the release owner, after it passes locally. The
release request carries `local: <what ran locally + result>`; a change that cannot run locally says why there.

## Subagents

Bounded work inside a lane (test steps, e2e runs, evals, research, review) is a subagent of the lane owner, never
its own session: SKILL.md → DISPATCH step 1.

Brief contents, model choice and supervision: `subagents.md`. Every brief carries a wall-clock budget (default
10 min, max 20) plus "return partial at the budget — never keep going", a short report, and the KB-first line
(below). Subagents never wait on a deploy, CI run or lock; the parent owns every wait (ONE status check, then
dispatch the proof). A subagent that hits a wait reports `merged/pushed, proof pending: <what to check>` and exits.
Release prep in a subagent is read-only with ONE dry run; never re-run a proof already recorded.

A subagent that edits a live file (a hook, a skill, a config) starts only after the parent has backed up the
original. The parent confirms the edit is wired and tested, or restores the backup, before it reports done.

## KB first

**Existing-work sweep first.** Before building or designing anything, list the existing work for the job and name
it in the first report line as `extends: <doc, role or script path>`: approved designs (spec folders, design docs),
the knowledge base's rules for the area, and the project's own start scripts and run commands. A Resume Here is a
pointer, never the full picture. A design, function or script that duplicates an existing one is rejected unless
the report says why the existing one cannot be extended. Run the app the way the project runs it (its start
scripts); never substitute another run path because it is easier.

Before calling any requirement new, search the project's knowledge base (a docs folder, a wiki, a search tool the
project provides) for prior decisions, and cite the doc path or URI. A requirement already decided is applied,
never re-invented. Every subagent brief carries: "search the project's knowledge base first, cite what you used".

## Issue tracker

Only when an issue tracker is configured (`COS_JIRA_BASE`):
- The card matches reality at all times: in progress at start; a comment at each milestone (state, evidence hash
  or proof, what's left, blocker + on whom); at DONE move it to the review column, never the final Done column
  (that one is the user's).
- Every report status line ends with `jira: <KEY> <status>`; `stop.sh DONE` refuses without it.
- No card → search the project, else create one and name it in your report.

## Messaging

Message other sessions with the `SendMessage` tool to the session NAME, never by typing into a pane. If you must
type into a pane, follow it with a separate submit key press and read the screen to confirm the text left the
input box (`comms.md` → *Panes*). The live chief's name is in `$COS_DIR/CHIEF` (re-read it before messaging: it
changes on takeover); a release owner's in `$COS_DIR/CAPTAIN` when one is set. A review request or queue entry
goes by SendMessage; a task file alone never reaches another session.
A session list row that looks exited is not proof. Before treating the chief, the release owner or a lead as down,
check `sessions.sh --tsv` (live row + pid) or the CHIEF / CAPTAIN / LEADS files.
- **Send only what the receiver must act on now.** Each message wakes the receiver into a turn that re-reads its
  whole context; the text is ~150 tokens (`comms.md` → *Send only what the receiver must act on now*). No acks
  (silence = received), no FYI or "no reply needed", no who-is-who broadcasts (CHIEF / CAPTAIN files are the
  truth). Status and proof go to your task file Reports. One message per receiver per turn. No `me → you:` prefix:
  the receiver already sees the sender name. The send-lean-guard hook denies ack, no-action and broadcast sends;
  escape `# wake-ok: <reason>`.
- **Codes** for fixed kinds, first word of the message; plain words for anything else:
  `RR <repo> <branch>@<sha> → dev|prod · local:<proof>` release-request · `LIVE <repo> <sha> <env> · <proof>` ·
  `BACK <repo> <sha> · <why>` send-back · `REVIEW <item> · <path>` · `GO <item>` / `NO <item> · <why>` verdict ·
  `HANDOFF <ctx>k · spawn <next> --continues <me> · RH <file>` · `TOOK <old> · <adopted>` ·
  `DONE <task> · <hash>` · `Q <question>` / `A <answer>`.
- **Waiting = chasing.** A session blocked on another names it in its status line (`blocks: <session> — <what>`)
  and checks actively: it reads that session's task file Reports, and if nothing new arrives within 20 min it sends
  ONE SendMessage status question. Never idle silently on another session.
- **Depended-on sessions answer at once.** A status question about a deploy, fix or review gets a reply in the
  same turn it arrives, before other work.
- A cold session (last turn older than `COS_SEND_COLD_MIN`, default 50 min) is not messaged: its cache is gone.
  The send-cold-guard hook denies it; spawn a successor with `--continues` instead.

## Release and prod agents

With 2+ builders live, builders never merge the shared branches and never deploy: one release owner session does
(SKILL.md → *Critical rules*). Every release request carries `kb: <doc>` or `kb: none-found (<query>)`, plus the
`local:` line from *Test tiers*. Release mechanics (request format, trains, one shared-branch merge per batch) live
in the project's own runbook; changes to a plugin repo go branch → tests → version bump → review → merge.
Agent or bot configuration that runs in prod follows the same one-way-door rule as a deploy: a lock row, an undo,
one proof turn.

## Domain leads

`$COS_DIR/LEADS` lists one long-lived lead session per major domain (optional). Work touching a listed domain →
that lead reviews your plan and gives `APPROVED` before you build, and again before the release request.
SendMessage the lead by name only for a review, a behaviour question in its domain, or an improvement idea; never
FYIs, status or proof (those go in your task file).

**Lane owners.** A lead may keep a team roster `$COS_DIR/teams/<domain>.md`: one row per lane = lane name, owner
session, scope (areas, repos/paths, epics), status. An issue inside a lane's scope goes to that lane's owner, even
when it is busy: it queues there. A new builder session is only for a lane with no owner, approved by the lead,
and it gets a roster row the same turn. Tests and evals run as the lane owner's subagents. A lane owner that hands
over keeps the lane: successor `--continues`, roster row updated. A builder that finds an issue outside its lane
sends it to the lead, never fixes it or spawns for it.

**Lead rules.** Before approving a change, the lead checks which goal the change serves and that every entry path
of the feature still passes. Measure first: check where real traffic goes before choosing what to fix.

## Limits

Every new or changed rate limit, concurrency cap, timeout, retry cap, truncation or fallback timer needs a row in
the project's limits document (if the project keeps one), and a limit that fires logs on the user's row or job.
A limit never cuts what an agent can see (instructions, loaded skill text, tool history, context); tune it only for
money, rate or safety. Reviewers block a diff that adds a limit without a row. Commit the row in the same step you
write it. A limits file many sessions edit is synced with `shared-checkout-sync.md`, never read-modify-written.

## Secrets in files

Never save a raw env or API export that holds real secret values (a hosting provider's env dump, a decrypted env
pull, an infra API's app JSON) into specs, docs, repos or the state dir. Record key NAMES + lengths + a sha256
prefix only. A raw dump truly needed for undo goes chmod 600 under your session scratchpad and is deleted after.
A secret-masking runner cuts masked values from stdout, so a signed URL printed there is cut off: write it to a
file from inside the child process.

**Transcripts are never deleted.** Claude transcripts (`~/.claude/projects/**/*.jsonl`, incl. subagent files) are
never deleted, moved or pruned by any session. Temp-dir cleanup checks that task output entries are symlinks into
the transcripts dir and never touches their targets.

## Context size and handover

Context is measured, not felt: before asking the chief for a handover or successor, run `ctx.py` and read your own
row against its `at` column, your handover point (task `handoff_at`: spawn.sh stamps the role's default from
`lib/handoff.py`; the context-handoff guard re-measures it). Under `at`: carry on. At `at` (ctx.py NEEDS-YOU, or
the context-handoff guard blocks your stop): write Resume Here (`/agent-ops:session-update` or a handoff skill),
then ask. A handoff is a wind-down too: run step 3 of *Wind-down* first and put `refs: proposed <N>` or
`refs: none (why)` in the Resume Here block and the `status: HANDOFF` line.

**Watchers and leads with a Monitor or session crons hand over the same way.** (1) At the handover point: Resume
Here, then ask the chief for a successor. Never `spawn.sh --task-file` your own running task (it refuses). The chief
writes `tasks/<line>-<N+1>.md` and spawns it `--continues <old> --fresh-ok` (`--light` for read-only watchers).
(2) The successor arms its own crons, Monitor and pending one-shots (ids in the predecessor's Resume Here) first,
then messages the predecessor. (3) Only then the predecessor stops its Monitor and crons, writes HANDOFF with
`refs:`, and idles. `stop.sh` exit 7 while a Monitor still runs is expected until step 3.

**Handover lists uncommitted work.** Every Resume Here has an `Uncommitted work` section: `git status --short` of
each repo the session touched, each file with its owner or `owner unknown`. The successor's first report marks each
item committed, handed to an owner, or listed to the user. A session that parks with uncommitted work it owns
commits it to a branch and pushes first.

**Refs run in the session that learned them.** At handoff or wind-down, run `/agent-ops:session-update` and the
references-update step in THIS session, before the HANDOFF or DONE line. Never hand the references step to a
successor: it lacks the learnings. Start a handoff early enough to finish both.

**Continuity.** A successor runs the existing-work sweep (KB first) and names its `extends:` path before any build.
It reads its predecessor's Resume Here and task file Reports first, reconciles with git in every repo they name,
and posts one status line. Then it prints a short HISTORY recap for the pane (max 15 lines: what the predecessors
did, where it is now with hashes, open asks, existing designs for the job), because the successor has no
scrollback. Before it reports a predecessor's fix as live, it checks the CONTENT on the prod commit
(`git show <sha>:<file> | grep <line>`), never merge-base ancestry: a hold-out cut drops
the content while ancestry still holds. If the predecessor is still live, it asks the predecessor for its Resume
Here first. A live predecessor's transcript is never mined; a cold one without Resume Here is mined by a cheap
subagent (continuity ladder rung 4, SKILL.md).

**Steering file.** `steering/<name>.md` holds every turn the user typed in a session, verbatim with time, written
by `steering-export.py` from the transcript (no LLM). spawn.sh `--continues` and stop.sh `HANDOFF` refresh it; the
context-handoff guard exports it when it fires. The successor walks the predecessor's steering file into a table in
its task file, one row per item: `done (evidence)` / `open (next step)` / `rule (where filed)` / `unclear`, and its
first `status: WORKING` line carries `steering: N items, M open`.
- **Interview:** while the predecessor is warm (live, or last turn < `COS_CONTINUITY_MIN`), SendMessage it the
  `unclear` items BEFORE reloading big docs: its answer costs a warm cache read, your reload a fresh cache write.
  Still unclear after its answer → one ask to the user.

## Hook-blocked commands

A Bash call that a hook blocks runs nothing. Re-run the parts that were not blocked; ask about the block once
(SKILL.md → *Critical rules*). A git pathspec that contains `[` needs the `:(literal)` prefix.

- zsh does not word-split `$VAR`: use an array (`H=(a b c); for h in $H`). A command held in a variable is an array
  (`cmd=(tool sub …)`, run `"${cmd[@]}"`), never a string.
- zsh reads `$var:x` as a history modifier (`:s`, `:h`, `:t`, `:r`, `:e`): `git show $b:src/f.ts` breaks. Brace and
  quote: `git show "${b}:src/f.ts"`.
- Monitor runs in zsh: put a watch loop in a file and run it with `/bin/bash <file>`.
- A Monitor on a growing Reports section re-emits rewritten lines. Dedupe by a line-hash file.
- Subagents never run a bare `git stash` / `git stash pop` (`git stash list` is fine).
- A guard that matches a word (e.g. a heavy-command guard matching a type-checker name) also matches it inside a
  heredoc that only writes a script. Write the script with the Write tool, then run it.
- Git hygiene: a worktree that symlinks `node_modules` needs bare `node_modules` in `.gitignore` (a trailing slash
  matches only directories). Stage explicit paths, never `git add -A`.

## Wind-down and teardown

Only when the whole task is finished (you report DONE, or the user signs off or says stop), never mid-task, in order:

1. **Teardown.** Stop every dev server and background process you started. For every git worktree you created:
   branch committed + pushed (or merged), then `git worktree remove <path>` (no `--force`; dirty → report it).
   Keep all branches (never `git branch -D`); `git worktree prune` in each repo touched. Report line
   `teardown: N worktrees removed, M kept (why)` — stop.sh refuses DONE without it. stop.sh also checks git: every
   worktree you created (stamped by the worktree-owner hook) must be removed or locked with a reason
   (`git worktree lock --reason "<why> (owner <you>)"`) before DONE, STOPPED, PARKED or HANDOFF, or it refuses (exit 9).
2. **Shipped.** Your user rules name a ship-tracking step → do it before DONE.
3. **Session + references.** `/agent-ops:session-update` (session file path in the report), then update the
   references: every rule, trap, correction or how-to learned goes to the skill or doc that owns it (or one
   proposal file, if the user runs a proposal gate). Report `refs: proposed <N> (<files>)` or `refs: none (why)`.
4. Send the wind-down message: one report line `DONE … session: <path> teardown: … refs: …`, then idle. The chief
   stops you with `stop.sh`; `reap.sh` closes you if the chief is away (`COS_REAP`).
