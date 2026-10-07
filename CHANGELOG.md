# Changelog

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
