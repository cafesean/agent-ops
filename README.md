# agent-ops

Run Claude Code like a chief of staff. One **chief** session triages what matters, keeps your goals in view, dispatches long work to **worker** sessions, and reports back in one place, the `Outstanding.md` list. Workers report through files, not chat, so nothing gets lost when a session dies.

Includes the session-logging family and plugin tooling.

## Skills
| Group | Skill | What it does |
|---|---|---|
| Orchestration | `/agent-ops:chief-of-staff` | BRIEF / SWEEP / dispatch loop over worker sessions |
| | `/agent-ops:init` | guided setup, writes the config, runs the doctor |
| Session logging | `/agent-ops:session-start` | open a session file (dated, tagged, RAG-friendly frontmatter) |
| | `/agent-ops:session-update` | append progress, decisions, lessons; the end-of-task session log workers write |
| | `/agent-ops:session-end` | close the session with a summary, drop it from the active tracker |
| | `/agent-ops:session-from-transcript` | rebuild a session file (with Resume Here) from a raw `.jsonl` transcript |
| | `/agent-ops:recap-session` | quick printed recap of a past session |
| | `/agent-ops:session-analysis` | mine session files for patterns and lessons to fold back into skills |
| Plugin tooling | `/agent-ops:plugin-authoring` | write agents/skills/hooks that trigger well; `check-plugin.sh` lints a plugin |
| | `agent-ops:agent-updater` (agent) | fold session lessons into SKILL.md / agent files in your plugin source repos (`COS_PLUGIN_REPOS`) |
| | `/agent-ops:version-bump` | bump plugin.json + marketplace.json (+ package.json), changelog, commit, tag; never pushes unasked |

Session files go to `.agent-ops.json` `sessionsDir` → `COS_SESSIONS_DIR` → `./sessions` (specs likewise: `specsDir` → `COS_SPECS_DIR` → `./specs`). Coming from claude-mem-pro: see [MIGRATION.md](MIGRATION.md).

## 60-second install
```
/plugin marketplace add cafesean/agent-ops
/plugin install agent-ops@agent-ops
/agent-ops:init
```
`init` asks a few questions one at a time (each has a default), writes `~/.claude/agent-ops/config.env`, seeds your state folder, records your first goals and runs a health check. Re-run it any time to change answers.

## The loop
```
   you ──goals──▶ GOALS.md
                     │
   BRIEF ◀───────────┤ (what matters now, ONE thing first)
     │               │
     ▼               │
  dispatch ──▶ tasks/<name>.md ──▶ worker session (tmux / cmux / wt)
     ▲                                   │
     │                         appends ## Reports, asks:
     │                                   ▼
   SWEEP (every 20 min) ──collect──▶ STATE.md + Outstanding.md ──▶ you
```
- **BRIEF**: reads STATE, GOALS and open tasks; tells you the one thing to do now.
- **Dispatch**: writes a task file with a task goal and a "done means" check, then starts a worker.
- **SWEEP**: collects worker reports, updates STATE, regenerates Outstanding, surfaces anything that needs you.

## Core vs add-ons
| Core (Claude Code + git only) | Add-ons (opt-in during init, off by default) |
|---|---|
| task files, spawn / queue / collect / stop | cmux panes (`COS_LAUNCHER=cmux`) |
| GOALS.md, STATE.md, Outstanding.md | Telegram alerts via Hermes |
| BRIEF and SWEEP | Jira items in Outstanding |
| tmux or wt launcher (print = manual fallback) | remote job runner for heavy commands |
| `doctor.sh` health check | multiple Claude accounts, load-balanced |
| session-start / update / end, from-transcript, recap, analysis | ADHD / focus mode |
| plugin-authoring, agent-updater, version-bump | key proxy: agents use API keys, never read them (`COS_VAULT_PORT`) |

An add-on with no config prints `addon <name> not configured, skipping` and exits cleanly. Core never needs an add-on.

## First run
1. `/agent-ops:init`, accept the defaults, write 1-3 goals in your own words.
2. Say "brief me". The chief reads your goals and proposes the first task.
3. Say "go" and the chief writes `tasks/<prefix>-<topic>.md` and starts a worker in its own window (with the print launcher you paste the printed `claude` command yourself).
4. Keep working. The sweep collects reports every 20 minutes.
5. Check `Outstanding.md`. The **Needs you** section is the only list you have to watch.

## Do I need tmux?
Yes, or one of the other terminal tools. Hands-off workers need a launcher that opens each worker in its own window or pane, so the chief and the queue can start workers by themselves.

| `COS_LAUNCHER` | What happens |
|---|---|
| `tmux` (mac, Linux, WSL) | Workers start by themselves; you can watch and talk to them |
| `cmux` (macOS add-on) | Same, as panes in the chief's workspace |
| `wt` (Windows Terminal, Git Bash) | Same, as Windows Terminal tabs |
| `print` | Manual fallback: spawn.sh only prints the `claude` command and you paste it into a terminal yourself. The sweep and the queue cannot start anything |

Install tmux:
```bash
brew install tmux          # macOS
sudo apt install tmux      # WSL / Ubuntu
```
Windows Git Bash: use `COS_LAUNCHER=wt` (Windows Terminal).

## Talking to a worker
Workers are ordinary interactive Claude Code sessions. You can talk to any of them at any time: answer a question, change direction, review its work.
1. Find it. tmux: `tmux attach -t agent-ops` (or your `COS_TMUX_SESSION`; add `-L <name>` / `-S <path>` if you set `COS_TMUX_SOCKET`); each window is named after the worker. cmux: panes in the chief's workspace. wt: a tab titled with the worker name.
2. Click in (tmux: switch to its window) and type, as in any Claude Code session.
3. The worker follows you and adds a one-line note under `## Reports` of `tasks/<name>.md`. The task file stays the record: the chief reads it, not the window.
4. Closing a worker's window or pane kills that worker. To end one cleanly, ask the chief to stop it (`stop.sh` kills the worker, closes its tmux window or cmux pane and closes the task; a wt tab stays open for you to close).

## Health check
```
bash "${CLAUDE_PLUGIN_ROOT}/skills/chief-of-staff/scripts/doctor.sh"
```
Read-only. Prints a PASS/WARN/FAIL table and exits 1 on any FAIL. Set `AGENT_OPS_CONFIG` to check a different config file.

## Windows (untested — please report issues)
**WSL2 (recommended)** — agent-ops runs as on Linux, tmux included:
```bash
wsl --install -d Ubuntu            # in PowerShell, once; then open Ubuntu
sudo apt update && sudo apt install -y git tmux python3 jq
# install Claude Code inside WSL, then: /plugin install agent-ops  →  /agent-ops:init
```
**Git Bash** (what Claude Code uses natively for hooks and Bash) also works, best effort:
- Python: `python3`, `python` or `py -3` is found automatically (`COS_PYTHON` in config overrides).
- Paths in config must be `/c/Users/you/…`, not `C:\…` (lists are colon-separated; `C:\` paths are converted with `cygpath` when possible).
- Launcher: `COS_LAUNCHER=wt` opens each worker in a Windows Terminal tab (`wt.exe -w 0 new-tab`); `stop.sh` ends the worker but the tab stays open. `print` is the manual fallback: you paste each command yourself.
- Keep LF line ends (`git config core.autocrlf false` before cloning); a CRLF-edited `config.env` is tolerated.

Known limits: no cmux (macOS only); `load-check.sh` is approximate on Git Bash (no load/memory figures, verdict LOCAL with a `note:`); the multi-account add-on needs the macOS Keychain (prints `addon accounts: macOS only, skipping` elsewhere); nothing here has been run on a real Windows machine yet.

## FAQ
**Does it work without cmux?** Yes. Use `tmux` (mac, Linux, WSL) or `wt` (Windows Terminal) and workers still start by themselves. Without any of them only `print` is left: it prints each `claude` command and you paste it into a terminal yourself, so the chief and the queue cannot start workers on their own. See *Do I need tmux?*

**Do I need Obsidian?** No. State is plain markdown in `~/agent-ops/state` by default. If you use Obsidian, point the state folder into your vault and it syncs like any other note.

**Where do secrets go?** Not in the config. Tokens such as `JIRA_API_TOKEN` come from your environment or secret store. `init` never asks for them.

**Can I run it on two machines?** Yes. Give each machine its own prefix letter. Each machine writes only its own tasks and its own block in Outstanding.

## License
MIT. See [LICENSE](LICENSE). Author: Sean Liao.
