# Add-on: hardware — where work runs, and the remote job runner

Load gating is core (`load-check.sh`). The remote job runner is optional: `mini-run.sh` prints `addon mini-run not configured, skipping` when `COS_REMOTE_HOST_KEY` / `COS_REMOTE_USER` are empty.

## This machine
`${CLAUDE_PLUGIN_ROOT}/skills/chief-of-staff/scripts/load-check.sh` gives the verdict:
| Verdict | Meaning | Chief does |
|---|---|---|
| `LOCAL` | room here | spawn locally |
| `LOCAL_LIGHT` | build/test workers running, or free memory near the floor | local only for read-only work; builds go remote or queue |
| `OFFLOAD` | load per CPU > `COS_MAX_LOAD_PER_CPU`, free memory < `COS_MIN_FREE_MEM_PCT`, or ≥ `COS_MAX_LOCAL_SESSIONS` live sessions | spawn.sh refuses a build worker (exit 3) unless `--light`/`--force`; the task stays `open` and the queue retries |

- **Orphans are always killed**: build/test workers whose parent is pid 1 (their session died) are killed on every `load-check.sh` run (TERM, wait, then KILL).
- **Load, not session count, decides OFFLOAD.** Many idle sessions on a quiet machine are not busy: judge by load per CPU and free memory, never by how many sessions are open. The load bit has hysteresis (`lib/loadgate.py`): it enters OFFLOAD when 5-min load per CPU passes `COS_LOAD5_ENTER` and leaves only below `COS_LOAD5_LEAVE`, so it does not flap. The agent-budget-guard hook reads the same bit and caps live subagents (`COS_MAX_LIVE_SUBAGENTS`).
- **Orphans**: any dev server, build or test process whose owning session is dead is killed, not left running; dev servers that die with their session are restarted by the next worker that needs them, never kept alive by a watcher.
- **Never two heavy type-checks / builds / test suites at once** on one machine; serialise them, or send them to the runner.
- The heavy-cap-guard hook denies a heavy local command (full suite, big type-check, production build) while `COS_MAX_HEAVY_LOCAL` (default 2) already run on this machine; `# heavy-ok: <reason>` in the command, or `COS_ALLOW_HEAVY_CAP=1`, overrides it. Send the job to the runner instead.
- If a memory watchdog runs on the machine, a build that "just dies" with no error is usually it; check its log first. Workers never disable a shared watchdog.
- Workers never start or stop shared dev servers.

## Remote job runner
Every Claude worker session stays on THIS machine. Workers send heavy COMMANDS to a remote machine with `mini-run`; remote Claude sessions (`spawn.sh --remote`) only for repo-free research/review. No dev servers, DBs or `.env` secrets on the runner.

**Use the runner** for: full test suites (> ~1 min), type-checks on big repos, production builds.
**Keep local**: anything needing a local DB, Redis, tunnels, a dev server, browser proof, `.env`; quick single-file tests.

```bash
cd <repo or worktree>
${CLAUDE_PLUGIN_ROOT}/skills/chief-of-staff/scripts/addons/mini-run.sh pnpm test
mini-run.sh 'pnpm typecheck && pnpm vitest run src/foo'   # one quoted arg = shell string
mini-run.sh --status        # who holds / waits for which repo dir
mini-run.sh --dry-run pnpm build
```
- **Mapping**: local launch dirs → remote dirs via `COS_REMOTE_LAUNCH_DIRS` (`LOCAL=REMOTE`). A worktree gets its own sibling dir on the runner.
- **Sync**: rsync `--delete` of the working tree incl. uncommitted files. Never sent: `.env*`, `.git`, `node_modules`, build output, logs, worktree dirs.
- **Lock**: one lock per remote dir; a second caller prints `queued: … busy` and waits (timeout → exit 91). Ctrl-C frees the lock.
- **Install**: when the lockfile or runtime version changed since the last run → frozen install there first (`--no-install` / `--install`).
- **Refuses** (exit 94, `--force` overrides) commands that look local-only: `dev`, `db:*`, `migrate`, e2e/integration tests, `start`.
- Exit codes: command's own · 90 setup · 91 lock timeout · 92 rsync · 93 install · 94 refused.
- Git state on the runner is not authoritative: its trees mirror whatever branch you ran from.
- Host address lives in your inventory (`COS_INVENTORY`, key `COS_REMOTE_HOST_KEY`); never paste it into docs or task files.

## Remote worker sessions (`spawn.sh --remote`)
Maps `--dir` through `COS_REMOTE_LAUNCH_DIRS`, refuses a missing remote dir (exit 2) or a full cap (`COS_REMOTE_MAX_SESSIONS`, exit 3), and opens a detached tmux window on the runner. `collect.sh` pulls its reports into the task file; `stop.sh` kills the window. Remote workers commit on a branch and never push. ssh fails → the task stays `open`; the queue retries.

## Workers that survive the terminal (tmux)
With `COS_LAUNCHER=tmux` every worker lives in a tmux server, not in the terminal app: quitting or crashing the terminal leaves workers running; `tmux attach -t ${COS_TMUX_SESSION:-agent-ops}` brings them back.
- **Headless spawn** (`COS_SPAWN_HEADLESS=1`): spawn.sh opens the worker in a detached tmux window on its own server (`COS_SPAWN_TMUX_SOCKET`) even when no terminal is open, e.g. from a scheduled sweep.
- **`scripts/addons/local-tmux.sh`** (macOS, optional): `install` puts that tmux server under a launch agent so it starts with the user session and survives the terminal app; `attach` / `reattach` show it in a terminal pane again. Off unless installed; prints `addon local-tmux not configured, skipping` otherwise.
- **`scripts/addons/wake-guard.sh`** (macOS, optional): at system sleep it pauses every Claude session; at wake it resumes warm ones and stops sessions whose cache went cold (idle ≥ `COS_WG_COLD_MIN`) through `stop.sh`, so a woken machine does not re-read every context at once. `install` adds the sleep/wake watcher.
- Workers on a cold cache (machine slept, idle past the cache window) get no cron, ping or SendMessage; the cold-cache-warn hook says so when the user types into one, and the send-cold-guard hook denies messages to one. Continue them with `--continues`.
