# Changelog

## 0.8.0
Chief of staff: the plugin is now the core chief only; everything specific to one setup moves to a user layer outside the plugin.
- **User layer** (`COS_USER_DIR`, default `$COS_DIR/user`): `rules.md` (your standing rules for the chief and workers), `bin/` (your scripts), `README.md`. The chief reads `rules.md` right after STATE.md; spawn.sh tells every worker to read it in turn 1; doctor reports it; init creates the skeleton and, for several machines, recommends one synced state folder they all share (config.env stays per machine).
- **Workers**: role pick (chief / builder / non-dev, `COS_BUILDER_DIRS`) with one rulebook pointer per section of `references/worker-rules.md`; continuity ladder (`--continues`, `--resume`, exit 6 while the old session is warm); per-worker environment command (`COS_SPAWN_ENV_CMD`); handover point per role (`handoff_at`).
- **Lifecycle**: `reap.sh` + `cos-reap` hook auto-close finished workers through every stop.sh gate; stop.sh refuses while an owned worktree is left behind (exit 9) or the user typed in the session recently (exit 8); `asks.py` keeps "Needs you" true (sweep, checks, short user queue); `ctx.py` and the context-handoff guard hand over before the context fills; `steering-export.py` carries the user's own words to a successor.
- **Load and cost guards** (hooks, all inactive without the config): heavy-cap-guard, agent-budget-guard with a load5 hysteresis gate, send-cold-guard, cold-cache-warn, ask-guard, worktree-owner.
- **Alerts**: `next.sh --alert` (queue, reap, asks sweep, dead-man stamps per machine) can pipe new alerts to any notifier via `COS_NOTIFY_CMD` (stdin); an external scheduler runs it. Optional hooks for the user layer: `COS_NEXT_HOOK_CMD` (one extra command per next.sh run), `COS_NEEDS_CHECK_CMD`, `COS_CMUX_HELPERS`, `COS_HEAVY_REMOTE_CMDS`.
- **Removed from the plugin** (now user-layer scripts if wanted): the scheduler/chat add-on, the remote job runner and its guard hook, the key proxy and secrets add-on, ship tracking (where-it-is, release-gap), cmux pane helpers, multi-account handling. Default machine prefix is now `a`.
- **Remote workers removed**: `spawn.sh --remote`, `sessions.sh --remote`, the ssh pull in `collect.sh`, the remote close in `stop.sh` and every `COS_REMOTE_*` key except `COS_REMOTE_CONTROL` (Claude Code's `--remote-control` flag). Several machines work together only through one shared state folder: each runs its own chief and `queue-run.sh` and spawns the tasks addressed `to: <its prefix>`. The OS overrides (`COS_OS`, `COS_WSL`, `COS_PYTHON`) moved to their own *Platform* section of `config.example.env`.

## 0.7.10
Removed work-specific references (named companies, a private spec path, internal IDs) from `agent-no-refusals`, `agent-rule`, `agent-refusal-warn` and the `plugin-authoring` example. The pointer hooks now match agent, role, guardrail and refusal words only.

## 0.7.9 — 2026-11-12
New shared skill `agent-no-refusals` (facts not refusals; the single owner decides). Hooks: `agent-rule.sh` (UserPromptSubmit) injects a two-line pointer on agent prompts; `agent-refusal-warn.sh` (PreToolUse on Edit/Write/MultiEdit) warns, never blocks, on refusal wording in agent-touching files.

## 0.7.6 — 2026-11-07
`session-end` step 3 places durable lessons through the placement gate: the owning skill first, the repo `CLAUDE.md` only for rules every session needs before its first tool call.

## 0.7.5 — 2026-11-07
`plugin-authoring`: the skill-structure section now carries a six-check placement gate (owner, already there, universal vs type, turn-1 test, instruction not history, shortest text) that runs before any rule is added to a skill.

## 0.7.1 — 2026-10-26
`session-from-transcript` and `recall` open with the 5-rung continuity ladder (live → message, < 50 min → resume, cold + fresh Resume Here → read it, else mine, fact only → recall) so neither runs when a cheaper rung fits.

## 0.7.0 — 2026-10-07
`init` now sets the per-repo session, specs and memory folders (writes `.agent-ops.json`) and shows the result of `locations.sh`. New optional `memoryDir` / `COS_MEMORY_DIR`; `locations.sh` prints `MEMORY_DIR` (empty when unset) and `recall` searches it. Replaces claude-mem-pro's `init` path setup.

## 0.6.0 — 2026-10-07
New skill `recall`: librarian over session files, specs, CLAUDE.md and memory notes (paths from `locations.sh`); points to the artifact and section, never writes.

## 0.5.2 — 2026-10-07
Session paths: reuse an existing `_ai/sessions` / `_context` layout before falling back to `./sessions` / `./specs`. `MIGRATION.md` no longer claims claude-mem-pro paths are read (they were not).

## 0.5.1 — 2026-10-07
Key proxy is macOS only.
- `install.sh` drops the untested Linux/systemd branch and refuses on any other OS; the add-on stays off there.
- `keyproxy.md`, `secrets.md`, `init` and `doctor.sh` say so: on Linux and Windows leave `COS_VAULT_PORT` unset and rely on the "use keys, never read them" rule.

## 0.5.0 — 2026-10-07
Bundled key proxy add-on: agents USE API keys through a loopback proxy and never READ them.
- `chief-of-staff/scripts/addons/keyproxy/`: `keyproxy.py` (stdlib daemon on 127.0.0.1; bearer / header / basic / query auth; strips caller credentials; no SSRF, no redirects followed; rejects browsers and bad Host headers; redacts the secret from replies; audit log without headers, queries or bodies), `keyproxy-set.py` (add/rotate from a hidden prompt, stdin or the macOS clipboard), `keyproxy-health`, `install.sh` (the user runs it with sudo; macOS LaunchDaemon under a dedicated service user; `--uninstall [--purge]`), `test_keyproxy.py`.
- `references/addons/keyproxy.md` (new) and `secrets.md` *How a session gets a key* now point at the bundled proxy.
- `init` offers the proxy and prints the sudo install command for the user; `doctor.sh` reports its health when `COS_VAULT_PORT` is set; `config.example.env` notes `COS_VAULT_PORT=8787`.

## 0.4.0 — 2026-10-07
Removed the `make-plan`, `do` and `babysit` skills.
- `agent-updater`: new section *No hosts, no secrets, genericize on the way in* (placeholder table, scan before inserting, grep after editing, rotate anything already committed).
- `plugin-authoring`: new `references/no-secrets.md` with the same table and grep.

## 0.3.2 — 2026-10-07
Docs: launchers and talking to workers.
- README: new *Do I need tmux?* (tmux / cmux / wt start workers by themselves; `print` is a manual fallback) with install lines, and *Talking to a worker*. FAQ "Does it work without cmux?" rewritten.
- `init`: explains what each launcher does before asking; recommends installing tmux when no tmux / cmux / wt is found.
- `chief-of-staff` SKILL.md + `references/comms.md`: *Working with workers directly* (workers are interactive; the task file stays the record; closing a window kills its worker).
- `spawn.sh`: the default worker prompt tells a worker to follow direct direction from the owner and add a one-line note under `## Reports`.
- `doctor.sh`: `COS_LAUNCHER=print` (or unset with no tmux / wt) is now a WARN: workers will not start by themselves.

## 0.3.1 — 2026-10-07
First public release.

**Orchestration (`chief-of-staff`)**
- BRIEF / SWEEP / dispatch loop over worker sessions that report through task files (`tasks/<name>.md`), with GOALS / STATE / Outstanding.
- Core scripts: `spawn`, `queue-run`, `collect`, `stop`, `sessions`, `next`, `outstanding`, `archive`, `checkin`, `load-check`, `waste-watch`, `doctor` (read-only health check).
- Launchers: `COS_LAUNCHER=tmux|cmux|wt|print`; `COS_TMUX_SOCKET` runs workers on their own tmux server.
- Short generic worker prompt; add your own standing rules with `COS_WORKER_PROMPT_EXTRA` (examples in `references/worker-prompt-examples.md`).
- `stop.sh … DONE` gate: needs `session:` + `teardown:`; optionally `refs:`, `shipped:`, `jira:`.
- `archive.sh`: closed tasks and old briefs move to `_archive/`, never deleted.
- Opt-in add-ons: cmux panes, Telegram via Hermes, Jira in Outstanding (`COS_JIRA_BASE` + `COS_JIRA_JQL`), remote runner for heavy commands + guard hook, multi-account (macOS Keychain), secrets vault (`COS_VAULT_PORT`), release-gap / where-it-is, focus-aware mode.

**Session logging**
- Skills `session-start`, `session-update`, `session-end`, `session-from-transcript`, `recap-session`, `session-analysis`.
- Artifact locations resolve per project: `.agent-ops.json` (`sessionsDir`, `specsDir`) → `COS_SESSIONS_DIR` / `COS_SPECS_DIR` → `./sessions` and `./specs`.

**Workflow and plugin tooling**
- Skills `make-plan`, `do`, `babysit`.
- `plugin-authoring` skill with a read-only lint (`scripts/check-plugin.sh`), `agent-updater` agent, `version-bump` skill.

**Setup and platforms**
- `/agent-ops:init` guided setup: copies `config.example.env` to `~/.claude/agent-ops/config.env`, seeds state templates, asks the worker permission mode (skip-permissions is opt-in only).
- macOS and Linux; Windows (Git Bash / WSL) support is untested. Python resolved via `COS_PYTHON` autodetect.
