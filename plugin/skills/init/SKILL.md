---
name: init
description: "Use when setting up or changing the agent-ops chief of staff on this machine — a guided, idempotent wizard that detects tools, asks a few questions one at a time, writes the config, seeds the state folder (STATE, GOALS, Outstanding), records your first goals, runs the doctor and offers the sweep. Triggers: \"set up chief of staff\", \"init agent ops\", \"/agent-ops:init\", \"configure my chief of staff\", \"get me running with a chief of staff\", \"reconfigure agent-ops\", \"add the Telegram/Jira add-on\"."
---

# agent-ops init

Guided setup. Idempotent: a re-run updates, never silently overwrites.

## Rules
- Ask INLINE as plain text, ONE question per message, each with a recommended default in brackets. Never use a popup/question tool. Empty reply or "ok" = take the default.
- Never ask for, print or write secrets (API tokens, passwords, chat secrets). Say: "tokens go in your environment or secret store, never in config.env".
- Paths: `INIT=${CLAUDE_PLUGIN_ROOT}/skills/init`, `SCRIPTS=${CLAUDE_PLUGIN_ROOT}/skills/chief-of-staff/scripts`, `CONFIG=${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}`.
- Existing file (config or any seed) → build the new version in a temp file, show `diff -u old new`, ask "apply? [no]". Never overwrite without a yes. Existing GOALS.md goals are never removed.

## Step 1 — Detect (one command, one table)
```bash
uname -s; grep -qi microsoft /proc/version 2>/dev/null && echo WSL
for t in claude git tmux cmux wt.exe hermes jq python3 python py cygpath; do printf '%s\t%s\n' "$t" "$(command -v $t || echo -)"; done
ls -d "$HOME"/Documents/*/.obsidian "$HOME"/*/.obsidian "$HOME"/Obsidian/*/.obsidian 2>/dev/null | sed 's#/.obsidian##'
[ -f "$CONFIG" ] && echo "existing config: $CONFIG"
```
Report one table `tool | found | used for`. `claude` + `git` missing → stop and say how to install. Existing config → load its values as the defaults for every question below ("update mode").
OS from `uname -s`: `Darwin` = mac, `Linux` = linux (plus `WSL` line = WSL2), `MINGW*`/`MSYS*`/`CYGWIN*` = Windows Git Bash. No python 3 at all (python3, python or `py -3`) → stop and say how to install. On Windows Git Bash say once: "Windows is untested — WSL2 is recommended; report issues." and write every path as `/c/Users/<you>/…` (never `C:\…`; colon lists break on drive letters). On WSL paths are `/home/…` or `/mnt/c/…`.

## Step 2 — Ask (one at a time)
1. **State dir** — default `~/agent-ops/state`; if a vault was found, offer `<vault>/agent-ops` as an alternative (state is plain markdown, syncs with the vault).
2. **Launcher** — `tmux` | `cmux` | `wt` | `print`. Default: mac/linux/WSL → `cmux` if found (mac only), else `tmux` if found, else `print`; Windows Git Bash → `wt` (Windows Terminal tab) if `wt.exe` found, else `print` (prints the exact `claude` command for you to run). Never offer `cmux` off macOS.
3. **Launch dirs** — colon list of repo roots workers may start in. Default: the current working dir. Each must exist.
4. **Machine prefix** — one lowercase letter for this machine (worker names start `<letter>-`). Default `m`.
5. **Max local sessions** — live top-level `claude` sessions before new work queues. Default `4`.
6. **Worker permission mode** — explain first: "Workers run unattended in their own window. By default they STOP at every permission prompt and wait until you answer in that window — safe, but slow. You can opt in to a skip-permissions flag so they run every tool without asking; that means a worker can edit, delete or run anything in its launch dir with no check. Keep the default? [yes]". Default → leave `COS_WORKER_CLAUDE_FLAGS` commented. Only if the user explicitly says they want skip-permissions AND confirms they understand the risk, set `COS_WORKER_CLAUDE_FLAGS="--dangerously-skip-permissions"`. A middle option is `--permission-mode acceptEdits` (file edits allowed, other tools still ask). Never turn it on by default or on an unclear answer.
7. **Session files dir** — where `/agent-ops:session-start|update|end` write session logs; default `./sessions` (relative = inside each repo root). Ask in the same breath for the specs dir, default `./specs`. Write `COS_SESSIONS_DIR` / `COS_SPECS_DIR` only when they differ from the defaults. A repo can override both with `.agent-ops.json` (`sessionsDir`, `specsDir`).
8. **Add-ons**, one question each, default OFF:
   - Telegram via Hermes (needs `hermes`): ask for the target name from `hermes send --list telegram` (`COS_HERMES=1`, `COS_TELEGRAM_TARGET`).
   - Jira in Outstanding: ask base URL (`COS_JIRA_BASE`) + JQL for "waiting on me" (`COS_JIRA_JQL`). Token stays in `$JIRA_API_TOKEN`. When on, `stop.sh … DONE` also needs a `jira:` tag.
   - Remote job runner: inventory file path, host key, remote user, remote prefix letter, `LOCAL=REMOTE` dir pairs (`COS_INVENTORY`, `COS_REMOTE_HOST_KEY`, `COS_REMOTE_USER`, `COS_REMOTE_MACHINE_PREFIX`, `COS_REMOTE_LAUNCH_DIRS`).
   - Multi-account: `auto` (load-balance logins added later with `account-add.sh`) vs `a` (default login only) (`COS_DEFAULT_ACCOUNT`).
   - Ship tracking (`COS_SHIPPED`, see `references/orchestration.md`): when on, a DONE that moved code also needs a `shipped:` line.
   - Require reference updates at DONE (`COS_REQUIRE_REFS=1`): workers must report `refs:` (docs updated, or "none").
   - Focus-aware mode (`COS_ADHD_MODE=1`, see [focus-aware mode](../chief-of-staff/references/addons/adhd.md)): one-screen answers, ONE Thing first, drift nudges.

## Step 3 — Write config
The only template is `${CLAUDE_PLUGIN_ROOT}/skills/chief-of-staff/config.example.env`.
1. `mkdir -p "$(dirname "$CONFIG")"`. Config missing → copy `config.example.env` to `$CONFIG`. Config present → copy the CURRENT config to a temp file and edit that.
2. Set each answered key: replace its line, or uncomment the `# KEY=` line and set the value. Core: `COS_DIR`, `COS_LAUNCHER`, `COS_LAUNCH_DIRS`, `COS_MACHINE_PREFIX`, `COS_MAX_LOCAL_SESSIONS`, `COS_SESSIONS_DIR` / `COS_SPECS_DIR` (non-default only); `COS_MONOREPO` = first launch dir; vault chosen → `COS_VAULT`. Add-on keys only for add-ons the user turned on; everything else stays commented (= off). Never write a token.
3. Existing config → show `diff -u "$CONFIG" <temp>` and ask "apply? [no]".
4. `chmod 600 "$CONFIG"`.

## Step 4 — Seed state
`mkdir -p "$COS_DIR/tasks" "$COS_DIR/briefs"`. For each of `STATE.md GOALS.md Outstanding.md`: missing → copy from `$INIT/templates/` with `{{PREFIX}}` and `{{DATE}}` filled; present → leave it (offer a diff only if the user asks). `templates/task.md` is the task-file skeleton the chief copies into `tasks/` — do not seed a task.

## Step 5 — First goals
Ask: "What are 1-3 things you want done in the next few weeks? Your words." For each answer write a block into GOALS.md (replace the `G1 · <outcome…>` placeholder first, then append G2, G3; never reuse an ID):
```
### G<n> · <short outcome, from their words>
intent: "<their words, verbatim>"
done means: <ask "how will you know it's done, and by when?" — or `— (owner to say)`>
status: confirmed
- tracked: —
```
Never invent their words. No answer → keep the placeholder with `status: confirm?`.

## Step 6 — Doctor, then offer the loop
Run `AGENT_OPS_CONFIG="$CONFIG" bash "$SCRIPTS/doctor.sh"` and show its table. FAIL rows → say the fix, offer to re-ask that one question. Then ask, one at a time:
- "Arm the sweep now? It runs `/agent-ops:chief-of-staff sweep` every 20 min in this session [yes]" → CronCreate `*/20 * * * *` (skip if an identical cron exists).
- "Run your first BRIEF now? [yes]" → invoke the chief-of-staff skill in BRIEF mode.

Finish with: config path, state dir, goals written, doctor verdict, cron armed or not. Re-run `/agent-ops:init` any time to change answers.
