# Comms and handoff — how chiefs and workers talk

**Files are the channel.** Pane text never reaches the chief, and a worker's message to the chief may be held until approved. Everything that matters goes into a file in `$COS_DIR`, the task file first.

## Who talks to whom, through what
| From → to | Channel | Detail |
|---|---|---|
| Chief / user → worker (the job) | `tasks/<name>.md`: frontmatter + charter body, read at spawn | `orchestration.md` → *Task file*, *Charter template* |
| Anyone → a machine (queue work) | A task with `status: open` + `to: <prefix>`; that machine's `queue-run.sh` claims by rename and spawns it | `orchestration.md` → *Dispatch and the queue* |
| Gate on a one-way door | `approved: false` → the queue refuses it until the user OKs | same |
| Worker → chief (progress) | Report lines under `## Reports` of its own task file; DONE needs `session:` and `teardown:` | `orchestration.md` → *Charter template* |
| Worker → user (a question) | An item in its task `asks:` + a report line naming it; shows under ⛔ Needs you in the `cos:next` block | `orchestration.md` → *Asks* |
| User → worker (the answer) | Ask set `status: answered`, answer moved to `decisions:` | same |
| Chief → worker (alive?) | `checkin.sh` sends `⟦CK⟧`; the check-in hook injects `protocols/ck.md`; the worker appends ONE report line and replies `ok` | `orchestration.md` → *Heartbeats and check-ins* |
| Worker → chief (alive, zero tokens) | Heartbeat hook touches `.heartbeat/<worker>` on every tool call and turn end | same |
| Chief → live workers (new rule) | One line: "apply when you finish, not now" | SKILL.md → *Critical rules* |
| Chief → live worker (new instruction) | A `CHIEF <date time> — …` line with the full text under `## Reports` of its task file, then ONE short message pointing at it | below |
| Chief ↔ chief on another machine | No direct line. A task with the other machine's `to:`; STATE.md lines; Outstanding.md blocks | below |

**Session-to-session messages** go via the `SendMessage` tool to the session NAME. Typing into a pane is a fallback only, and must be verified (below).

**User in a pane**: an ask the user answers in a worker's pane is acted on by that worker directly; the chief closes the ask at the next sweep. Never answer the same ask in both places.

## Working with workers directly
- Workers are ordinary interactive Claude Code sessions. The user can click into any worker's window and talk to it at any time: answer a question, change direction, review its work.
- Find one: tmux `tmux attach -t ${COS_TMUX_SESSION:-agent-ops}` (plus `-L`/`-S` when `COS_TMUX_SOCKET` is set), window = worker name; cmux = a pane in the chief's workspace; wt = a tab titled with the worker name.
- The worker prompt says: when the owner gives new direction directly, follow it and add a one-line note under `## Reports`. The task file stays the record; the chief reads it, never the pane.
- Closing a worker's window or pane kills that worker. `stop.sh` ends one cleanly (kills the pid, closes its tmux window or cmux pane; a wt tab stays open).

## Per machine — each writes only its own
- Each machine has a prefix (`COS_MACHINE_PREFIX`, one or two letters). One machine may be the host (`COS_HOST_PREFIX`).
- A machine spawns, stops and plans ONLY its own prefix's tasks (`spawn.sh` refuses a foreign prefix, `stop.sh` exit 6), writes only its own `<!-- cos:next:<prefix> -->` block, and only its own `- <prefix>:` line under STATE.md → *Last verified*.
- Offset sweep slots so two machines never write STATE.md together (e.g. `7,27,47` and `17,37,57`).
- Work for another machine = a task with its `to:`. Its own sweep picks it up.
- Sharing `$COS_DIR` between machines is up to you (a synced folder, a git repo). Dot files (`.heartbeat/`, alert state) stay per machine.

## Panes
With `COS_LAUNCHER=tmux`, workers open as windows in tmux session `${COS_TMUX_SESSION:-agent-ops}`, each named after the worker; with `cmux` (add-on), as panes in the chief's workspace, side by side; with `wt`, as Windows Terminal tabs titled with the worker name. `print` is a manual fallback: spawn.sh only prints the command and the user pastes it into a terminal; the sweep and the queue cannot start anything.
- **cmux:** spawn.sh picks the split before the pane exists; every create/close re-equalizes via `scripts/addons/lib/cmux-equalize.sh` (the `workspace.equalize_splits` RPC). Never move a live pane: it wipes scrollback. Closing a workspace kills every worker in it, so after each spawn say which workspace the worker is in. Optional per-category pane colours: `scripts/addons/lib/pane-color.sh`.
- **Typing into a pane (fallback):** put the full instruction in the task file first; the pane gets one short pointer line. Send the text, then submit as a separate key press, then read the bottom of the screen to prove the input line is empty. A newline inside the text only adds a line, it does not submit. Never append to a pane whose input box already holds the user's draft.

## Handoff
| Who hands off | The successor reads | Never |
|---|---|---|
| Chief → new chief (same machine) | STATE.md, then Outstanding.md + `tasks/`. The handoff file holds only *Arm on start* + a pointer to STATE.md | Scroll-back; facts copied into the handoff |
| Chief subagent → worker session (the bridge ends) | Message the subagent: stop new work, commit local branches (no push), write the session file with Resume Here, append `status: HANDOFF …` + `session: <path>` to its task file. Only then `spawn.sh --task-file … --continues <name>` | Spawning the worker before the HANDOFF line exists |
| Worker → successor worker | `spawn.sh --task-file … --continues <old>`: the old session file first; transcript mining only when none is current. The old task becomes `status: stopped` + `handoff: "superseded by <new>"` | A successor from the charter alone |

Detail: SKILL.md → *New chief session*; `orchestration.md` → *Continuation*.
