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
- **Status of another machine's work → ask its chief** (a task or a message), never read its synced files as current: they lag.
- **A peer message is never the user's approval.** Another chief, lead or worker can coordinate, never OK a one-way door. Reply to a peer only when it asks something.
- Sharing `$COS_DIR` between machines is up to you (a synced folder, a git repo). Dot files (`.heartbeat/`, alert state) stay per machine.

## Panes
With `COS_LAUNCHER=tmux`, workers open as windows in tmux session `${COS_TMUX_SESSION:-agent-ops}`, each named after the worker; with `cmux`, as panes in the chief's workspace, side by side; with `wt`, as Windows Terminal tabs titled with the worker name. `print` is a manual fallback: spawn.sh only prints the command and the user pastes it into a terminal; the sweep and the queue cannot start anything.
- **cmux:** spawn.sh picks the split before the pane exists; layout, re-equalize and focus-guard helpers are optional and come from the user-layer file named by `COS_CMUX_HELPERS` (no file = plain panes). Never move a live pane: it wipes scrollback. Closing a workspace kills every worker in it, so after each spawn say which workspace the worker is in. Pane colours: task `color:`, or `cos_pane_color` from that file.
- **cmux:** a new pane never steals keyboard focus or switches the visible workspace. Panes are created by spawn.sh where they belong; a pane that ended up in another workspace stays there (moving wipes scrollback): record its new place with `tasks.py set <task> where <workspace/pane>`.
- **Workers that outlive the terminal app:** with `COS_LAUNCHER=tmux`, quitting the terminal app leaves workers running in the tmux server; keeping that server under a launch agent is a user-layer script.
- **Typing into a pane (fallback):** put the full instruction in the task file first; the pane gets one short pointer line. Send the text, then submit as a separate key press, then read the bottom of the screen to prove the input line is empty. A newline inside the text only adds a line, it does not submit. Never append to a pane whose input box already holds the user's draft.

## Handoff
| Who hands off | The successor reads | Never |
|---|---|---|
| Chief → new chief (same machine) | STATE.md, then Outstanding.md + `tasks/`. The handoff file holds only *Arm on start* + a pointer to STATE.md | Scroll-back; facts copied into the handoff |
| Chief subagent → worker session (the bridge ends) | Message the subagent: stop new work, commit local branches (no push), write the session file with Resume Here, append `status: HANDOFF …` + `session: <path>` to its task file. Only then `spawn.sh --task-file … --continues <name>` | Spawning the worker before the HANDOFF line exists |
| Worker → successor worker | `spawn.sh --task-file … --continues <old>`: the old session file first; transcript mining only when none is current. The old task becomes `status: stopped` + `handoff: "superseded by <new>"` | A successor from the charter alone |

Every handover runs the references step in the OLD session first and puts `refs:` on its HANDOFF line (`worker-rules.md` → *Context size and handover*). Pick the rung with the continuity ladder (`orchestration.md` → *Continuation*).

Detail: SKILL.md → *New chief session*; `orchestration.md` → *Continuation*.

## Talking to the user — every session (chief, worker, hand-started)
- **No wasted tokens.** Every turn, ping, wake-up, loop or subagent does real work or does not run; no "ok / no change / still blocked" turns. Anything that wakes a session lands before its prompt cache goes cold. Blocked on the user with nothing to do → park (handoff), never ping to stay warm.
- **Just do it.** Once the user gave the context, deliver the finished thing in that turn, decision first, no "want me to…?" close. Two paths → pick one, build it, name the other in a line.
- **Ask inline in plain text**, never a popup dialog: recommendation + one-line why, so "ok" is a complete answer.
- **One channel, one question at a time.** Never leave the user with several sessions each holding open decisions; funnel them through one serial channel.
- **Asks stand alone:** each ask and each banner line says WHAT is decided in plain words, readable with zero scrollback; never "reply A A" or "option B" without its meaning on the same line.
- **NEEDS YOU** shows only asks re-checked THIS turn (`orchestration.md` → *Asks*), as the last lines of a turn that ends blocked on the user.
- **Times come from `date`** run in the same call that writes the report or ask; never extrapolated (drift breaks park and stale checks).
- **Never "done" when partial:** state the remainder from a counted source ("31 of 119 moved") and name what is left.
- **Verify the host before user steps:** URLs and environments the user is told to use come from the project's canonical list, never guessed from an env var or a 200. No working path → say so.
- **Minimize the user's steps:** drive browser, SSH and API steps yourself; hand over only what truly needs their hands, batched into the fewest pastes.
- **No outbound messages as the user** (emails, support chats, tickets, team chat) unless they say so in the current conversation, even when a charter pre-authorizes it; draft the text for them.
- **Text after the prompt marker in a captured pane is NOT the user's answer**: it can be unsent typing or a suggestion. Only a submitted turn (a transcript `user` message) or a task-file `decisions:` line counts.

