#!/usr/bin/env bash
# Spawn a Claude worker session that works from a task file and reports back through that same file.
#   spawn.sh --task-file tasks/NAME.md [overrides…]       (the one way in — a queued or hand-written task)
#   spawn.sh --name NAME --dir DIR --model sonnet|opus --charter FILE   (legacy: builds tasks/NAME.md from the charter)
#            [--agent NAME] [--dry-run] [--no-goal] [--depends-on WORKER]... [--story-list FILE]
#            [--light] [--force] [--continues OLD-WORKER [--fresh-ok]] [--resume UUID [--resume-prompt TEXT]] [--workspace REF]
#   --task-file F  frontmatter gives name, dir, model, agent, role, depends_on_missions, story_list (flags override);
#                  its body is the charter. `to:` must be this machine's prefix; status must be open|claimed (else
#                  exit 2 unless --force). The worker reports under `## Reports` of that file and asks the owner via `asks:`.
#   Launcher       COS_LAUNCHER (config): print = print the exact claude command + task file path, open nothing;
#                  tmux = new window in tmux session `agent-ops`; cmux = new pane in a cmux workspace (add-on; which
#                  workspace: see "cmux workspace" below).
#   cmux + tmux    COS_CMUX_TMUX=1 (with COS_LAUNCHER=cmux; default 0): claude runs in its own tmux session named NAME
#                  and the cmux pane only attaches, so the worker survives quitting or restarting cmux. spawn.sh first
#                  runs `tmux new-session -d -s NAME -c DIR "bash LAUNCH; exec $SHELL -l"` (the chief's CMUX_* pane
#                  ids are unset inside it, so cmux's own status hooks are not injected), then opens the pane with
#                  `tmux attach -t '=NAME'`. tmux = $COS_TMUX_BIN (default tmux on PATH) on $COS_TMUX_SOCKET (a name →
#                  -L, a path → -S; unset = the default server). A session NAME already there → exit 2. where: gets a
#                  `/tmux:NAME` suffix; stop.sh kills that session. A ⟦CK⟧ typed into the pane reaches claude through
#                  the attach. After a cmux restart the panes are gone but the sessions live on: re-opening attach panes
#                  for them is a user-layer script (e.g. `tmux ls` → `cmux new-pane --command "tmux attach -t '=NAME'"`).
#   --agent NAME   passed through as `claude --agent NAME`.
#   --dry-run      print the goal, the task file and the launch commands; write nothing, launch nothing.
#   --no-goal      allow a charter that says `parent goal: none` (PARK risk).
#   --depends-on W another worker that must finish first (repeatable).
#   --story-list F the feature's story_list.json (else the charter's `story list:` line).
#   --light        read-only worker: may start while load-check says OFFLOAD.  --force: start anyway.
#   --model        haiku|sonnet|opus (task `model:`; default opus).
#   --continues OLD  continue OLD's work. Local only. CONTINUITY LADDER first (cheapest context wins):
#                  OLD still LIVE → exit 6 "SendMessage it" (rung 1); OLD's last transcript turn (lib/lastturn.py)
#                  < COS_CONTINUITY_MIN (50) min → exit 6 with the exact `spawn.sh --task-file … --resume <uuid>
#                  --resume-prompt` command (rung 2). --fresh-ok overrides both with a WARN (a fresh context on purpose:
#                  takeover, context full). FIRST STEP of the successor: a session file holding "Resume Here" written
#                  after OLD's last turn (or current by the report-line test) → read it, never mine; OLD live without
#                  one → ask OLD (SendMessage) for its Resume Here; only then the transcript. After launch OLD's task gets
#                  `handoff: superseded by NAME`; `status: stopped` + `closed:` only when OLD is not live.
#   --fresh-ok     see --continues. Without --continues (and no --resume), spawn WARNs when a same-topic task (same
#                  first two name words after the machine, digits dropped, or named in the charter body) closed
#                  < COS_CONTINUITY_MIN min ago — with its --resume command — or is live (SendMessage it).
#   --resume UUID  reopen a STOPPED worker's own session with the same launch flags (keeps the prompt cache). Local only.
#                  Needs --task-file. Transcript must sit under --dir's project slug (cwd is part of the cached
#                  prompt) → else exit 2. Live process for that session id or name → exit 2 (stop it first).
#                  Model: task `model:`, else the transcript's last assistant model (mismatch → WARN).
#                  Idle gate: last user/assistant turn > 60 min ago → exit 5 (cache cold; use --continues instead);
#                  --force overrides with a WARN.
#   --resume-prompt TEXT  (with --resume only) the resumed session's first prompt, appended after `--resume UUID`
#                  (a new turn after the cached context; flags unchanged, so the cache still holds). Plain --resume
#                  sends no first prompt.
#   --workspace REF  cmux launcher only: the workspace the pane opens in.
#   cmux workspace (COS_LAUNCHER=cmux), first hit wins; titles match case-insensitively; an empty `cmux tree --all`
#                  is retried once:
#                  1. --workspace REF / $COS_SPAWN_WORKSPACE (must be live, else exit 2);
#                  2. task `workspace_title:` — the workspace with that title; none → created at launch with
#                     `workspace create --json --id-format both`, the pane goes in the ref it RETURNS (never a tree
#                     re-read) and its placeholder shell is closed once the worker pane exists;
#                  3. a chief task (role chief: task `role: chief`, a *-chief / *-chief-* name, the CHIEF file's name)
#                     → the workspace titled $COS_CHIEF_WORKSPACE_TITLE (default CHIEF); missing → WARN, next rule;
#                  4. $COS_CMUX_WORKSPACE_ROUTES: `;`-separated PATTERN=TITLE; PATTERN is a case-insensitive shell glob
#                     matched against "<name> <category> <lane>" (task `category:` / `lane:`); first match wins; the
#                     workspace must already exist (never created) — else WARN, next rule;
#                  5. the $COS_CMUX_WORKSPACE pin while it is live; 6. the workspace titled $COS_CMUX_WORKSPACE_TITLE
#                     (default chief); 7. none → a new workspace named after the worker.
#                  --dry-run prints which rule picked the workspace. Task `title:` → the pane/tab title (default NAME).
#                  Focus guard: the owner's focus is snapped before any create and restored after.
# Launch-dir guard: --dir must be exactly one of $COS_LAUNCH_DIRS (colon-separated).
# Workers run on THIS machine only. Another machine runs its own chief + queue-run.sh over the shared $COS_DIR and
#   spawns the tasks addressed `to: <its prefix>`; there is no cross-machine launch.
# Load gate: load-check.sh OFFLOAD refuses a local worker (exit 3) unless --light or --force.
# Goal gate: the charter carries `task goal:`, `done means:` and `parent goal: <ID>` (a `### <ID> · ` heading in
#   $COS_GOALS, default $COS_DIR/GOALS.md). Missing task goal or unknown/parked parent → exit 2.
# NAME convention: <machine>-<topic>[-<specifier>][-N], lowercase, hyphen-joined; machine = $COS_MACHINE_PREFIX.
# Role: task `role:` (chief|builder|non-dev) wins; else chief when NAME is the CHIEF file's name for this machine or
#   ends -chief; builder when --dir is under one of $COS_BUILDER_DIRS (colon list; empty = every dir); else non-dev.
#   The first prompt carries one pointer line per section of references/worker-rules.md that applies to the role.
# Prompt extension: $COS_WORKER_PROMPT_EXTRA is added to every first prompt (the user's own standing rules), and when
#   $COS_USER_DIR/rules.md exists one line "User rules: read <path> in turn 1" (the user layer, outside the plugin).
# Env extension: $COS_SPAWN_ENV_CMD (optional, local workers) — a command the launch script runs at launch with
#   the task file path and the worker name as arguments; each stdout line `KEY=VALUE` (KEY matching
#   ^[A-Z_][A-Z0-9_]*$) is exported into the worker's environment. Other lines are ignored; values are never
#   printed, logged or written to a file. A failing command → WARN, the worker starts without them.
# Handover point: a new task file gets `handoff_at` from lib/handoff.py (role default); a value already set is kept.
# Exit codes: 2 refused/bad input · 3 OFFLOAD (load gate) · 5 resume idle gate · 6 continuity ladder.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"

# Launch scripts live under $LAUNCH_DIR. If COS_VAULT is set, vault paths reach argv only through a symlink
# alias (devault) so process-matching watchdogs that key on the vault path never hit a worker.
LAUNCH_DIR="${COS_LAUNCH_SCRIPT_DIR:-$COS_DIR/launch}"
[ "${DRY:-0}" = 1 ] || mkdir -p "$LAUNCH_DIR" 2>/dev/null || true
if [ -n "${COS_VAULT:-}" ]; then
  VAULT_ALIAS="${COS_VAULT_ALIAS:-$HOME/.claude/agent-ops/vault}"
  ln -sfn "$COS_VAULT" "$VAULT_ALIAS"
  devault() { case "$1" in "$COS_VAULT"|"$COS_VAULT"/*) printf '%s' "$VAULT_ALIAS${1#$COS_VAULT}";; *) printf '%s' "$1";; esac; }
else
  devault() { printf '%s' "$1"; }
fi

TASKF= TCOLOR_OVR= MODEL_SET=0 NAME= DIR= MODEL=opus TASK= CHARTER= AGENT= DRY=0 NOGOAL=0 LIGHT=0 FORCE=0 STORYLIST= DEPS=() CONT= PRED= PSESS= RESUME= RESUME_PROMPT= FRESH_OK=0 PLIVE=0 SSTATE= MODEL_SRC=default CONT_WHY= WS_ARG="${COS_SPAWN_WORKSPACE:-}"
while [ $# -gt 0 ]; do case "$1" in
  --name) NAME="$2"; shift 2;; --dir) DIR="$2"; shift 2;; --model) MODEL="$2"; MODEL_SET=1; MODEL_SRC=flag; shift 2;; --task-file) TASKF="$2"; shift 2;;
  --task) TASK="$2"; shift 2;; --charter) CHARTER="$2"; shift 2;;
  --agent) AGENT="$2"; shift 2;; --dry-run) DRY=1; shift;; --no-goal) NOGOAL=1; shift;;
  --depends-on) DEPS+=("$2"); shift 2;; --story-list) STORYLIST="$2"; shift 2;;
  --light) LIGHT=1; shift;; --force) FORCE=1; shift;;
  --resume-prompt) RESUME_PROMPT="$2"; shift 2;; --fresh-ok) FRESH_OK=1; shift;;
  --continues) CONT="$2"; shift 2;; --workspace) WS_ARG="$2"; shift 2;; --resume) RESUME="$2"; shift 2;;
  -h|--help) awk 'NR>1 && /^set -euo/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"; exit 0;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; done
TPY="$HERE/lib/tasks.py"
if [ -n "$TASKF" ]; then
  [ -f "$TASKF" ] || { echo "refuse: no task file $TASKF" >&2; exit 2; }
  tget() { cos_python "$TPY" get "$TASKF" "$1"; }
  [ -n "$NAME" ] || NAME=$(tget name)
  [ -n "$DIR" ] || DIR=$(tget dir)
  [ "$MODEL_SET" = 1 ] || { m=$(tget model); [ -z "$m" ] || { MODEL="$m"; MODEL_SRC=task; }; }
  [ -n "$AGENT" ] || AGENT=$(tget agent)
  [ -n "$STORYLIST" ] || STORYLIST=$(tget story_list)
  [ -n "$CONT" ] || [ -n "$RESUME" ] || CONT=$(tget continues)   # resume = the SAME session, no predecessor step
  TCOLOR_OVR=$(tget color)   # optional `color:` override for the pane colour (cos_pane_color)
  [ "$(tget light)" != true ] || LIGHT=1   # read-only task: may start while load says OFFLOAD
  if [ "${#DEPS[@]}" = 0 ]; then while IFS= read -r d; do [ -z "$d" ] || DEPS+=("$d"); done < <(cos_python -c 'import json,sys;[print(x) for x in json.loads(sys.argv[1] or "[]")]' "$(tget depends_on_missions)"); fi
  TST=$(tget status); TTO=$(tget to)
  [ -n "$RESUME" ] || case "$TST" in open|claimed|"") ;; *) echo "refuse: task $NAME is '$TST' — only open|claimed tasks spawn (--force to respawn)" >&2; [ "$FORCE" = 1 ] || exit 2;; esac
  CHARTER="$TASKF"
fi
[ -n "$NAME" ] || { echo "need --task-file FILE, or --name --dir --charter FILE" >&2; exit 2; }
# Naming convention — checked before anything else so a bad name never gets half-spawned.
MACH_LOCAL="${COS_MACHINE_PREFIX:-a}"
LETTERS="a-z"
if ! [[ "$NAME" =~ ^[${LETTERS}](-[a-z0-9]+){1,3}$ ]]; then
  echo "bad --name '$NAME'. Rule: <machine>-<topic>[-<specifier>][-N], lowercase a-z0-9, hyphen-joined, 2-4 parts." >&2
  echo "  machine: $MACH_LOCAL = this machine (another machine spawns its own prefix). Examples: $MACH_LOCAL-auth-fix, $MACH_LOCAL-docs-2" >&2
  exit 2
fi
if [ "${NAME%%-*}" != "$MACH_LOCAL" ]; then
  # Per-machine ownership: this machine writes only its own prefix's tasks.
  echo "refuse: local worker name must start with '$MACH_LOCAL-' (COS_MACHINE_PREFIX on this machine), got '$NAME' — spawn it on its own machine, or --force" >&2
  [ "$FORCE" = 1 ] || exit 2
fi
[ -z "$TASKF" ] || [ -z "$TTO" ] || [ "$TTO" = "${NAME%%-*}" ] || { echo "refuse: task $NAME is addressed to '$TTO', not this name's machine '${NAME%%-*}'" >&2; exit 2; }
[ -z "$RESUME_PROMPT" ] || [ -n "$RESUME" ] || { echo "refuse: --resume-prompt needs --resume UUID" >&2; exit 2; }
[ -n "$DIR" ] && [ -n "$CHARTER" ] && [ -f "$CHARTER" ] || { echo "need --dir and a charter/task file (--task-file F | --charter F)" >&2; exit 2; }
# Resume — same session, same flags; anything that would change the cached prompt is refused or WARNed.
RTRANS=
if [ -n "$RESUME" ]; then
  [[ "$RESUME" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "bad --resume '$RESUME' — a session uuid" >&2; exit 2; }
  [ -n "$TASKF" ] || { echo "refuse: --resume needs --task-file tasks/<name>.md (model, dir, agent come from it)" >&2; exit 2; }
  [ -z "$CONT" ] || { echo "refuse: --resume and --continues don't mix — resume reopens the SAME session" >&2; exit 2; }
  RTRANS="$HOME/.claude/projects/$(printf '%s' "${DIR%/}" | tr '/.' '--')/$RESUME.jsonl"
  if [ ! -f "$RTRANS" ]; then
    other=; for f in "$HOME"/.claude/projects/*/"$RESUME".jsonl; do [ -f "$f" ] && { other="$f"; break; }; done
    [ -z "$other" ] && echo "refuse: no transcript $RESUME.jsonl under ~/.claude/projects/ — wrong session id?" >&2 \
      || echo "refuse: transcript is $other, not under --dir $DIR's project — the session ran from another dir (cwd is part of the cached prompt); fix the task's dir:" >&2
    exit 2
  fi
  # Idle gate — after 60 min the prompt cache is cold. Last user/assistant turn, not mtime.
  RMT=$(cos_python "$HERE/lib/lastturn.py" "$RTRANS" 2>/dev/null | cut -d' ' -f1 || true)
  if [[ "$RMT" =~ ^[0-9]+$ ]]; then
    RIDLE=$(( ($(date +%s) - RMT) / 60 ))
    if [ "$RIDLE" -gt 60 ]; then
      if [ "$FORCE" = 1 ]; then echo "WARN: session idle $RIDLE min > 60 — cache cold, resume re-reads the whole context at full price (--force)" >&2
      else echo "refuse: session idle $RIDLE min > 60 — cache cold; use --continues $NAME instead (or --force)" >&2; exit 5; fi
    fi
  else echo "WARN: cannot read last turn of $RTRANS — idle check skipped" >&2; fi
  TMODEL=$(cos_python - "$RTRANS" <<'PYM'
import json, sys
last = ""
for l in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if '"assistant"' not in l: continue
    try: d = json.loads(l)
    except Exception: continue
    m = (d.get("message") or {}).get("model") or ""
    if d.get("type") == "assistant" and m and not m.startswith("<"): last = m
print(last)
PYM
)
  case "$TMODEL" in *opus*) TALIAS=opus;; *sonnet*) TALIAS=sonnet;; *haiku*) TALIAS=haiku;; *) TALIAS=;; esac
  if [ "$MODEL_SRC" = default ]; then
    [ -n "$TALIAS" ] || { echo "refuse: task has no model: and the transcript's last model '${TMODEL:-none}' maps to no spawn alias (haiku|sonnet|opus) — set model: in the task file" >&2; exit 2; }
    MODEL="$TALIAS"; MODEL_SRC="transcript ($TMODEL)"
  elif [ -n "$TALIAS" ] && [ "$TALIAS" != "$MODEL" ]; then
    echo "WARN: resuming with --model $MODEL ($MODEL_SRC) but the transcript last ran $TMODEL — a model change re-reads the whole context (cache miss)" >&2
  fi
  # Live check — one session, one process. Kill (stop.sh NAME) must come first.
  LIVE=$(cos_python - "$RESUME" "$NAME" <<'PYL'
import glob, json, os, sys
sid, name = sys.argv[1:]
for f in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try: d = json.load(open(f)); os.kill(d.get("pid"), 0)
    except Exception: continue
    if d.get("sessionId") == sid or d.get("name") == name: print(f"pid {d.get('pid')} ({d.get('name') or '-'}, session {d.get('sessionId')})"); break
PYL
)
  [ -n "$LIVE" ] || LIVE=$("$HERE/sessions.sh" --tsv 2>/dev/null | awk -F'\t' -v n="$NAME" '$1=="live" && $2==n {print "pid " $3 " (" n ")"; exit}')
  if [ -n "$LIVE" ]; then
    if [ "$DRY" = 1 ] && [ "$FORCE" = 1 ]; then echo "WARN: $NAME / session $RESUME still live: $LIVE — dry-run only (--force); a real resume refuses until it is stopped" >&2
    else echo "refuse: $NAME / session $RESUME still has a live process: $LIVE — stop it first (stop.sh $NAME), then resume" >&2; exit 2; fi
  fi
  TASKP_RESUME="$TASKF"
fi
case "$MODEL" in haiku|sonnet|opus) ;; *) echo "model must be haiku|sonnet|opus" >&2; exit 2;; esac
[ -z "$AGENT" ] || [[ "$AGENT" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "agent must be [A-Za-z0-9._:-]" >&2; exit 2; }
AGENT_FLAG=; [ -n "$AGENT" ] && AGENT_FLAG="--agent $AGENT "
for d in "${DEPS[@]+"${DEPS[@]}"}"; do [[ "$d" =~ ^[a-z](-[a-z0-9]+){1,3}$ ]] || { echo "bad --depends-on '$d' — a worker name" >&2; exit 2; }; done

# Launch-dir guard — Claude sessions start ONLY from the approved roots.
DIRN="${DIR%/}"; ok=0
ALLOWED="${COS_LAUNCH_DIRS:-}"
[ -n "$ALLOWED" ] || { echo "refuse: COS_LAUNCH_DIRS unset in $COS_CONFIG — list the approved launch dirs (colon-separated)" >&2; exit 2; }
IFS=: read -r -a _dirs <<< "$ALLOWED"
for a in "${_dirs[@]}"; do [ "$DIRN" = "${a%/}" ] && ok=1; done
[ "$ok" = 1 ] || { echo "refuse: --dir '$DIR' is not a launch dir. Allowed: ${ALLOWED//:/ | }" >&2
  echo "  Launch from one of those; name the repo the worker works in inside the charter." >&2; exit 2; }


# Continuation — resolve the predecessor's transcript by its custom title (the claude -n name).
find_pred() {   # newest transcript whose custom title is exactly $1, across --dir + every launch dir
  local d slug pd f
  { IFS=: read -r -a _pd <<< "$DIR:${COS_LAUNCH_DIRS:-}"
    for d in "${_pd[@]}"; do
      [ -n "$d" ] || continue
      slug=$(printf '%s' "${d%/}" | tr '/.' '--'); pd="$HOME/.claude/projects/$slug"; [ -d "$pd" ] || continue
      LC_ALL=C command grep -l -F "\"customTitle\":\"$1\"" "$pd"/*.jsonl 2>/dev/null || true
    done; } | sort -u | while IFS= read -r f; do printf '%s\t%s\n' "$(cos_mtime "$f")" "$f"; done | sort -rn | head -1 | cut -f2-
}
# Session file first — prints "<current|stale|none>\t<why>\t<path>". Rule in the header.
find_sess() {
  cos_python - "$1" "$COS_DIR" "$DIR" "${COS_VAULT:-}" "${COS_MONOREPO:-}" "${COS_LAUNCH_DIRS:-}" <<'PYS'
import os, re, sys, time
old, cos, d, vault, mono, launch = sys.argv[1:]
roots = [r for r in [vault, mono, d, *launch.split(":")] if r]
def resolve(p):
    p = os.path.expanduser(p.strip().strip("`'\"").rstrip(".,)"))
    if os.path.isabs(p): return p if os.path.isfile(p) else None
    for r in roots:
        q = os.path.join(r, p)
        if os.path.isfile(q): return q
    return None
KEY = re.compile(r"session(?:[ _]file)?(?: written| reconstructed| updated)?\s*:\s*`?([^`;·|]*?\.md)\b", re.I)
NOOP = re.compile(r"noop|\bidle\b|no[ -]change|unchanged|nothing new", re.I)
STAMP = re.compile(r"^status:\s*\S+\s+(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2})")
# live first, then _archive/ (archive.sh moves finished/parked workers' files there — still resumable)
cands = [os.path.join(cos, *p) for p in (("tasks", old + ".md"), ("inbox", old + ".md"), ("_archive", "tasks", old + ".md"), ("_archive", "inbox", old + ".md"))]
inbox = next((c for c in cands if os.path.isfile(c)), cands[1])
text = open(inbox, encoding="utf-8", errors="replace").read() if os.path.isfile(inbox) else ""
if inbox.endswith(".md") and "/tasks/" in inbox and "\n## Reports" in text: text = text[text.index("\n## Reports") + 1:]
lines = text.split("\n")
cand, idx, src, named = None, None, None, None
for i in range(len(lines) - 1, -1, -1):
    m = KEY.search(lines[i])
    if m:
        named = named or m.group(1).strip()
        f = resolve(m.group(1))
        if f: cand, idx, src = f, i, f"inbox/{old}.md line {i+1}"; break
if not cand:
    mp = next((c for c in [os.path.join(cos, *p) for p in (("tasks", old + ".md"), ("missions", old + ".yaml"), ("_archive", "tasks", old + ".md"), ("_archive", "missions", old + ".yaml"))] if os.path.isfile(c)), "")
    if os.path.isfile(mp):
        for l in open(mp, encoding="utf-8", errors="replace"):
            m = re.match(r"\s*(?:session_file|session file|session_link|handoff)\s*:\s*\"?([^\"#]*?\.md)\"?\s*$", l)
            if m and resolve(m.group(1)): cand, src = resolve(m.group(1)), f"missions/{old}.yaml"
if not cand:
    why = f"session file named ({named}) but not on disk" if named else f"no session line in inbox/{old}.md or missions/{old}.yaml"
    print(f"none\t{why}\t"); sys.exit()
real = [(i, l) for i, l in enumerate(lines) if l.startswith("status:") and not NOOP.search(l)]
after = [(i, l) for i, l in real if idx is None or i > idx]
if not after:
    print(f"current\tfrom {src}; no real-work status line after it (only noop/idle)\t{cand}"); sys.exit()
i, l = after[-1]; m = STAMP.match(l)
if not m:
    print(f"stale\tfrom {src}; real work at inbox line {i+1} after it, stamp unparseable\t{cand}"); sys.exit()
ts = time.mktime(time.strptime(m.group(1).replace("T", " "), "%Y-%m-%d %H:%M"))
mt = os.path.getmtime(cand); fm = time.strftime("%Y-%m-%d %H:%M", time.localtime(mt))
if mt >= ts: print(f"current\tfrom {src}; file mtime {fm} >= newest real-work line {m.group(1)}\t{cand}")
else: print(f"stale\tfrom {src}; real work at {m.group(1)} (inbox line {i+1}) after file mtime {fm}\t{cand}")
PYS
}
if [ -n "$CONT" ]; then
  [[ "$CONT" =~ ^[a-z](-[a-z0-9]+){1,3}$ ]] || { echo "bad --continues '$CONT' — a worker name" >&2; exit 2; }
  [ "$CONT" != "$NAME" ] || { echo "refuse: --continues names this worker itself — give the successor a new name (e.g. $NAME-2)" >&2; exit 2; }
  IFS=$'\t' read -r SSTATE SWHY PSESS <<< "$(find_sess "$CONT")"
  # Continuity ladder — live → SendMessage; last turn < COS_CONTINUITY_MIN → --resume; else a fresh successor.
  CMIN="${COS_CONTINUITY_MIN:-50}"
  PTRANS=$(find_pred "$CONT"); PLAST=; PIDLE=
  [ -z "$PTRANS" ] || PLAST=$(cos_python "$HERE/lib/lastturn.py" "$PTRANS" 2>/dev/null | cut -d' ' -f1 || true)
  [[ "$PLAST" =~ ^[0-9]+$ ]] && PIDLE=$(( ($(date +%s) - PLAST) / 60 )) || PLAST=
  PTASK=; for f in "$COS_DIR/tasks/$CONT.md" "$COS_DIR/_archive/tasks/$CONT.md"; do [ -f "$f" ] && { PTASK="$f"; break; }; done
  # the predecessor's latest HANDOFF report line should carry refs: — WARN only
  [ -z "$PTASK" ] || cos_python - "$PTASK" <<'PYH' || true
import re, sys
L = open(sys.argv[1], encoding="utf-8", errors="ignore").read().split("\n")
h = [i for i, l in enumerate(L) if re.search(r"status:\s*\**\s*HANDOFF\b", l)]
if h and not re.search(r"(?<![\w-])refs:\s*\S", "\n".join(L[h[-1]:])):
    print("WARN: predecessor HANDOFF line in %s has no refs: — the successor's first step gets its lessons into the reference docs and reports refs:" % sys.argv[1], file=sys.stderr)
PYH
  "$HERE/sessions.sh" --tsv 2>/dev/null | awk -F'\t' -v n="$CONT" '$1=="live" && $2==n {f=1} END {exit !f}' && PLIVE=1
  RESUME_CMD="$HERE/spawn.sh --task-file $(printf '%q' "${PTASK:-$COS_DIR/tasks/$CONT.md}") --resume $(basename "${PTRANS:-<uuid>}" .jsonl) --resume-prompt '<the new ask>'"
  if [ "$PLIVE" = 1 ]; then LADDER="$CONT is LIVE — rung 1: SendMessage $CONT the new ask (zero new context)"
  elif [ -n "$PIDLE" ] && [ "$PIDLE" -lt "$CMIN" ]; then LADDER="$CONT's last turn was $PIDLE min ago (< $CMIN, cache warm) — rung 2: $RESUME_CMD"
  else LADDER=; fi
  if [ -n "$LADDER" ]; then
    if [ "$FRESH_OK" = 1 ]; then echo "WARN: $LADDER — spawning a fresh successor anyway (--fresh-ok)" >&2
    else echo "refuse: $LADDER. A fresh context on purpose (takeover, context full) → add --fresh-ok." >&2; exit 6; fi
  fi
  # FIRST STEP: Resume Here written after the last turn → read it; live predecessor → ask it; transcript last.
  if [ -n "$PSESS" ] && grep -q 'Resume Here' "$PSESS" 2>/dev/null && { [ -z "$PLAST" ] || [ "$(cos_mtime "$PSESS")" -ge "$PLAST" ]; }; then
    SSTATE=current; SWHY="Resume Here in $PSESS written after $CONT's last turn"
  fi
  if [ "$SSTATE" = current ]; then
    CONT_WHY="session file (current) — $SWHY"
  elif [ "$PLIVE" = 1 ]; then
    CONT_WHY="ask the LIVE predecessor (SendMessage) for its Resume Here — never mine a live session ($SWHY)"
  else
    PRED="$PTRANS"
    if [ -n "$PRED" ]; then CONT_WHY="transcript — $SWHY"; PSESS=
    elif [ "$SSTATE" = stale ]; then CONT_WHY="session file (STALE, no transcript found) — $SWHY"
      echo "WARN: no transcript for $CONT — using the stale session file; the worker must reconcile git carefully" >&2
    else echo "refuse: no current session file ($SWHY) and no transcript with \"customTitle\":\"$CONT\" under ~/.claude/projects/<launch-dir slug>/ — check the old worker's exact name (sessions.sh, LEDGER)" >&2; exit 2; fi
  fi
elif [ -z "$RESUME" ]; then
  # Same-topic check — no --continues: a same-topic task closed < COS_CONTINUITY_MIN ago should be resumed, a live one messaged.
  LIVEN=$("$HERE/sessions.sh" --tsv 2>/dev/null | awk -F'\t' '$1=="live" {printf "%s ", $2}' || true)
  while IFS=$'\t' read -r ON OMIN OTASK; do
    [ -n "$ON" ] || continue
    if [ "${ON%%-*}" != "${COS_PREFIX:-}" ]; then echo "same-topic $ON on machine ${ON%%-*}: not this machine, no resume" >&2; continue; fi
    if [ "$OMIN" = live ]; then echo "WARN: same-topic $ON is LIVE — rung 1: SendMessage $ON instead of a new worker (or --continues $ON)" >&2
    else OT=$(find_pred "$ON"); echo "WARN: same-topic $ON closed $OMIN min ago (cache warm) — rung 2: $HERE/spawn.sh --task-file $(printf '%q' "$OTASK") --resume $(basename "${OT:-<uuid>}" .jsonl) --resume-prompt '<the new ask>'" >&2; fi
  done < <(cos_python - "$COS_DIR" "$NAME" "$CHARTER" "${COS_CONTINUITY_MIN:-50}" "${LIVEN:-}" <<'PYT'
import glob, os, re, sys, time
cos, name, charter, cmin, live = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), set(sys.argv[5].split())
now = time.time()
def topic(n): return "-".join([w for w in n.split("-")[1:] if not re.fullmatch(r"\d+", w)][:2])
body = open(charter, encoding="utf-8", errors="replace").read()
if body.startswith("---\n"): body = body.split("\n---", 1)[-1]   # body only — frontmatter from:/continues: name the chief
for f in glob.glob(os.path.join(glob.escape(cos), "tasks", "*.md")):
    o = os.path.basename(f)[:-3]
    if o == name or not (topic(o) == topic(name) or re.search(rf"(?<![\w-]){re.escape(o)}(?![\w-])", body)): continue
    fm = open(f, encoding="utf-8", errors="replace").read().split("\n---", 1)[0]
    m = re.search(r"^closed:\s*\"?(\d{4}-\d{2}-\d{2} \d{2}:\d{2})", fm, re.M)
    c = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M")) if m else None
    if o in live: print(f"{o}\tlive\t{f}")
    elif c is not None and 0 <= now - c < cmin * 60: print(f"{o}\t{int((now - c) // 60)}\t{f}")
PYT
)
fi

# Load gate.
LOAD=$("$HERE/load-check.sh" 2>/dev/null | head -1 || true)
case "$LOAD" in
  OFFLOAD*)
    if [ "$LIGHT" = 1 ]; then echo "WARN: $LOAD — starting anyway (--light: read-only worker)" >&2
    elif [ "$FORCE" = 1 ]; then echo "WARN: $LOAD — starting anyway (--force)" >&2
    else echo "refuse: $LOAD. Queue it, --light for a read-only worker, or --force." >&2; exit 3; fi;;
  LOCAL_LIGHT*) [ "$LIGHT" = 1 ] || echo "WARN: $LOAD — only read-only work belongs here now" >&2;;
esac

# Goal gate — every worker has its own task goal; a GOALS.md goal is its parent.
GOALS="${COS_GOALS:-$COS_DIR/GOALS.md}"
hdr() { sed -nE "s/^[-*[:space:]]*\**$1\**:\**[[:space:]]*(.*)$/\1/p" "$CHARTER" | head -1 | sed -E 's/[[:space:]]+$//'; }
TGOAL=$(hdr '[Tt]ask [Gg]oal')
TDONE=$(hdr '[Dd]one [Mm]eans')
TINTENT=$(hdr '[Ii]ntent')
[ -n "$STORYLIST" ] || STORYLIST=$(hdr '[Ss]tory[ _][Ll]ist' | sed -E 's/^`(.*)`$/\1/')
GOAL=$(hdr '[Pp]arent [Gg]oal' | grep -oE '^[A-Za-z0-9]+' || true)
[ -n "$GOAL" ] || GOAL=$(hdr '[Gg]oal' | grep -oE '^[A-Za-z0-9]+' || true)   # legacy `goal: <ID>`
if [ -z "$TGOAL" ]; then
  echo "refuse: charter $CHARTER has no non-empty 'task goal:' line — one sentence, the outcome THIS task delivers" >&2
  echo "  (the owner's words where given). Header block: references/orchestration.md → Charter template." >&2; exit 2
fi
if [ -z "$GOAL" ]; then
  echo "refuse: charter $CHARTER has no 'parent goal: <ID>' line (legacy 'goal: <ID>' also accepted)." >&2
  echo "  IDs are the '### <ID> · ' headings in $GOALS. Serving none: write 'parent goal: none' and pass --no-goal." >&2; exit 2
fi
[ -n "$TDONE" ] || { echo "WARN: charter has no 'done means:' line — the worker gets no concrete finish check" >&2; TDONE="—"; }
# short slug of the task goal for inbox tags: first 4 content words, hyphen-joined
TSLUG=$(printf '%s' "$TGOAL" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' ' ' | tr ' ' '\n' \
  | grep -vxE '(a|an|the|and|or|of|to|for|in|on|at|by|from|with|his|her|own|so|can|every|all|it|its|is|are|be|that|this|through|via|them|they)?' \
  | head -4 | paste -sd- - || true)
[ -n "$TSLUG" ] || TSLUG="${NAME#*-}"
TG60="$TGOAL"; [ "${#TG60}" -le 60 ] || TG60="${TG60:0:59}…"
if [ "$GOAL" = none ]; then
  [ "$NOGOAL" = 1 ] || { echo "refuse: charter says 'parent goal: none' — pass --no-goal to spawn anyway (LEDGER marks it PARK risk)" >&2; exit 2; }
  GTAG="none·PARK-risk"; ITAG="[none] $TSLUG"
  PARENT_PROMPT="Parent goal: NONE from GOALS.md (spawned with --no-goal — PARK risk)."
else
  [ "$NOGOAL" = 0 ] || echo "WARN: --no-goal ignored — charter names parent goal $GOAL" >&2
  [ -f "$GOALS" ] || { echo "refuse: goals file $GOALS not found" >&2; exit 2; }
  GINFO=$(cos_python - "$GOALS" "$GOAL" <<'PY2'
import sys, re
path, gid = sys.argv[1:]
head = f"### {gid} · "
out, on = {}, False
for line in open(path, encoding="utf-8").read().split("\n"):
    if line.startswith(head):
        on = True; out["outcome"] = line[len(head):].strip(); continue
    if on and line.startswith("#"): break
    if on:
        m = re.match(r"^(intent|done means|status):\s*(.*)", line)
        if m and m.group(1) not in out: out[m.group(1)] = m.group(2).strip()
if not on: sys.exit(1)
for k in ("outcome", "intent", "done means", "status"): print(out.get(k) or "—")
PY2
) || { echo "refuse: parent goal '$GOAL' is not a '### $GOAL · ' heading in $GOALS" >&2; exit 2; }
  { read -r G_OUT; read -r G_INT; read -r G_DONE; read -r G_ST; } <<< "$GINFO"
  case "$G_ST" in parked*) echo "refuse: parent goal $GOAL is parked in $GOALS — un-park it, or use 'parent goal: none' + --no-goal" >&2; exit 2;; esac
  GTAG="$GOAL"; case "$G_ST" in confirmed*) ;; *) GTAG="$GOAL?";; esac
  ITAG="[$GOAL] $TSLUG"
  PARENT_PROMPT="Parent goal: $GOAL · $G_OUT (status: $G_ST). Intent: ${TINTENT:-$G_INT}."
fi
GOAL_PROMPT="YOUR TASK GOAL: ${TGOAL%.}. Done means: ${TDONE%.}. $PARENT_PROMPT Off-goal rule: if the next step doesn't serve your TASK goal, report BLOCKED off-goal in your inbox instead of doing it. Tag every inbox status line with '$ITAG', e.g. 'status: WORKING <YYYY-MM-DD HH:MM> $ITAG'."

STAMP=$(date '+%Y-%m-%d %H:%M')
# One task file is the charter, the inbox, the mission and the LEDGER row.
TASKP="$COS_DIR/tasks/$NAME.md"
[ -z "$RESUME" ] || TASKP="$TASKP_RESUME"   # resume updates the given task file, never re-stamps it
DEST_CHARTER="$TASKP"
INBOX="$TASKP"
MISSION="$TASKP"
# argv-safe (devault'd) copies — only for text that lands in a CMD string or the worker's prompt.
# Real vars above still point at the actual vault paths for every file-system operation.
DIR_SAFE="$(devault "$DIR")"
DEST_CHARTER_SAFE="$(devault "$DEST_CHARTER")"
INBOX_SAFE="$(devault "$INBOX")"
MISSION_SAFE="$(devault "$MISSION")"
NEWM=0; [ -f "$TASKP" ] || NEWM=1
# Task file: create it from the charter (legacy --charter), or take the given/queued one; then stamp the spawn fields.
write_task() {   # write_task FILE — FILE ends up a complete task file for this spawn (status claimed until launched)
  local f="$1"
  if [ -n "$TASKF" ] && ! [ "$TASKF" -ef "$f" ]; then cp "$TASKF" "$f"
  elif [ -z "$TASKF" ] && ! [ -f "$f" ]; then cos_python "$TPY" new "$f" --name "$NAME" --to "${NAME%%-*}" --from "${COS_FROM:-chief}" --status claimed --charter "$CHARTER"; fi
  local deps="[$(IFS=,; echo "${DEPS[*]+"${DEPS[*]}"}" | sed 's/,/, /g')]"
  cos_python "$TPY" set "$f" to "${NAME%%-*}" parent_goal "$GOAL" task_goal "$TGOAL" done_means "$TDONE" model "$MODEL" dir "$DIR" \
    depends_on_missions "$deps" heartbeat_min "${COS_HEARTBEAT_MIN:-60}" status claimed
  [ -z "$AGENT" ] || cos_python "$TPY" set "$f" agent "$AGENT"
  [ -z "$STORYLIST" ] || cos_python "$TPY" set "$f" story_list "$STORYLIST"
  [ -z "$CONT" ] || cos_python "$TPY" set "$f" continues "$CONT"
  [ -z "$CONT" ] || [ -z "$PSESS" ] || cos_python "$TPY" set "$f" predecessor_session "$PSESS"
  [ -z "$CONT" ] || [ -z "$PRED" ] || cos_python "$TPY" set "$f" predecessor_transcript "$PRED"
  # Handover point (lib/handoff.py): the role default for an empty one; a value already set (by the chief) is kept.
  if [ -f "$HERE/lib/handoff.py" ]; then
    if [ -z "$(cos_python "$TPY" get "$f" handoff_at 2>/dev/null)" ]; then
      HAT=$(cos_python "$HERE/lib/handoff.py" default "$NAME" "$f" 2>/dev/null || true)
      [ -z "$HAT" ] || cos_python "$TPY" set "$f" handoff_at "$HAT" handoff_r ""
    elif [ -n "$CONT" ]; then cos_python "$TPY" set "$f" handoff_r ""   # a successor keeps the point, re-measures its own R
    fi
  fi
}
if [ "$DRY" = 0 ] && [ -z "$RESUME" ]; then mkdir -p "$COS_DIR/tasks"; write_task "$TASKP"; fi
# Set top-level keys in a mission file (replace in place, else insert after parent_goal:). Values are JSON-quoted
# when they hold spaces, slashes or YAML-special characters, so next.sh's YAML subset reads them.
mset() {
  cos_python - "$@" <<'PY4'
import sys, re, json
p, *kv = sys.argv[1:]
L = open(p, encoding="utf-8").read().split("\n")
for k, v in zip(kv[::2], kv[1::2]):
    v = json.dumps(v, ensure_ascii=False) if re.search(r"[\s/#:\"']", v) else v
    i = next((n for n, l in enumerate(L) if re.match(rf"{re.escape(k)}:", l)), None)
    if i is not None: L[i] = f"{k}: {v}"
    else:
        j = next((n for n, l in enumerate(L) if re.match(r"parent_goal:", l)), 0)
        L.insert(j + 1, f"{k}: {v}")
open(p, "w", encoding="utf-8").write("\n".join(L))
PY4
}

dry_goal() {
  echo "DRY-RUN task goal: $TGOAL"
  echo "DRY-RUN done means: $TDONE"
  echo "DRY-RUN parent: [$GTAG] · inbox tag: $ITAG · ledger: [$GTAG] $TG60"
  [ -z "$CONT" ] || { echo "DRY-RUN continues: $CONT · FIRST STEP path = $CONT_WHY"
    echo "DRY-RUN predecessor session file: ${PSESS:-none} · predecessor transcript: ${PRED:-none (not mined)}"
    echo "DRY-RUN after spawn: tasks/$CONT.md → handoff: \"superseded by $NAME\"$([ "$PLIVE" = 1 ] && echo ' (live: status kept until its HANDOFF line)' || echo ', status: stopped')"; }
  echo "DRY-RUN prompt goal block: $GOAL_PROMPT"
  T=$(mktemp -d)/$NAME.md; [ ! -f "$TASKP" ] || cp "$TASKP" "$T"; write_task "$T"
  echo "DRY-RUN task file $TASKP$([ "$NEWM" = 0 ] && echo ' (exists — fields re-stamped)'):"; awk 'NR==1 || !/^---$/ {print} /^---$/ && NR>1 {print; exit}' "$T" | sed 's/^/  /'; rm -f "$T"
}
# Role — task role: wins; else chief (CHIEF file name for this machine / *-chief), builder (dir under COS_BUILDER_DIRS), non-dev.
CHIEF_NAME=$(awk -v p="$COS_PREFIX" '/^[[:space:]]*#/||NF==0{next} $1==p":" {print $2; f=1; exit} first=="" && $1 !~ /:$/ {first=$1} END{ if(!f && first!="") print first }' "$COS_DIR/CHIEF" 2>/dev/null || true)
ROLE=$( { [ ! -f "$TASKP" ] || cos_python "$TPY" get "$TASKP" role; } 2>/dev/null || true)
[ -n "$ROLE" ] || [ -z "$TASKF" ] || ROLE=$(cos_python "$TPY" get "$TASKF" role 2>/dev/null || true)
case "$ROLE" in chief|builder|non-dev) ;; *)
  ROLE=non-dev
  case "$NAME" in *-chief|*-chief-*) ROLE=chief;; *)
    if [ -n "$CHIEF_NAME" ] && [ "$NAME" = "$CHIEF_NAME" ]; then ROLE=chief
    elif [ -z "${COS_BUILDER_DIRS:-}" ]; then ROLE=builder
    else IFS=: read -r -a _bd <<< "$COS_BUILDER_DIRS"
      for b in "${_bd[@]}"; do [ -n "$b" ] || continue; case "${DIR%/}/" in "${b%/}/"*) ROLE=builder;; esac; done
    fi;;
  esac;;
esac
# Rulebook: one pointer line per section of references/worker-rules.md that applies to ROLE.
WR="$(dirname "$HERE")/references/worker-rules.md"
WR_SAFE="$(devault "$WR")"
RULES_PROMPT="RULEBOOK: $WR_SAFE (role: $ROLE). Each line below is a rule in short; read its § section when it applies."
RULES_PROMPT="$RULES_PROMPT ROLES (§ Roles): you are a $ROLE worker; stay inside your task."
RULES_PROMPT="$RULES_PROMPT ASKS (§ Asks and the NEEDS YOU banner): ask the owner only via the asks: block of your task file; a turn that ends blocked on the owner ends with the NEEDS YOU banner."
RULES_PROMPT="$RULES_PROMPT AUTONOMY (§ Autonomy): decide two-way doors yourself; ask only for one-way doors."
RULES_PROMPT="$RULES_PROMPT SPEED (§ Speed and heavy commands): parallel lanes for independent work, batch tool calls; heavy commands may be routed to another machine by a user-layer script (see your user rules); a status line every 30 min."
RULES_PROMPT="$RULES_PROMPT NO OVERDOING (§ No overdoing): do only what the next step of your goal needs; green stays green."
[ "$ROLE" != builder ] || RULES_PROMPT="$RULES_PROMPT TEST TIERS (§ Test tiers): one quick proof per change is the default; full regression only where the section says."
RULES_PROMPT="$RULES_PROMPT SUBAGENTS (§ Subagents): every brief has a wall-clock budget and returns partial at it; subagents never wait on deploys or locks."
RULES_PROMPT="$RULES_PROMPT KB FIRST (§ KB first): search the project's docs and knowledge base before calling anything new."
RULES_PROMPT="$RULES_PROMPT MESSAGING (§ Messaging): SendMessage to a session by name, never type into a pane.${CHIEF_NAME:+ Chief: $CHIEF_NAME.}"
[ "$ROLE" != builder ] || RULES_PROMPT="$RULES_PROMPT RELEASE (§ Release): never merge to the release branches or deploy yourself; follow the section."
[ "$ROLE" = chief ] || RULES_PROMPT="$RULES_PROMPT DOMAIN LEADS (§ Domain leads): work in a domain that has a lead needs the lead's approval first."
[ "$ROLE" != builder ] || RULES_PROMPT="$RULES_PROMPT LIMITS (§ Limits): any new or changed limit follows the section."
RULES_PROMPT="$RULES_PROMPT CONTEXT (§ Context size and handover): hand over near your task's handoff_at; never mid-step."
RULES_PROMPT="$RULES_PROMPT HOOK-BLOCKED (§ Hook-blocked commands): a hook refusal is a rule, not an obstacle; use the way it names."
RULES_PROMPT="$RULES_PROMPT WIND-DOWN (§ Wind-down and teardown): only when the whole task is finished."
[ -f "$WR" ] || RULES_PROMPT=
TAIL_PROMPT="Only when your whole task is finished (you report DONE, or the owner signs off or says stop) — never mid-task — run /agent-ops:session-update to write or update your session file (what changed, where it lives, how to resume) and put its path in your report line."
TEARDOWN_PROMPT="TEARDOWN at DONE: before your DONE report, stop every dev server/background process you started; for EVERY git worktree you created: make sure its branch is committed + pushed (or merged), then \`git worktree remove <path>\` (no --force; dirty → report it, never force); KEEP all branches; run \`git worktree prune\` in each repo you touched. Put a line in your report: \`teardown: N worktrees removed, M kept (why)\` — stop.sh refuses DONE without it."
STYLE_PROMPT="Style: concise. Report lines are one line each: verdict, evidence, what is next. No recaps, no filler. Never print secrets (keys, tokens, passwords) in tool output or reports."
# Opt-in standing rules (time-awareness, test tiers, subagent budgets, …): set COS_WORKER_PROMPT_EXTRA — examples in references/worker-prompt-examples.md.
# comma-joined (one argv, no glob); COS_WORKER_DISALLOWED_TOOLS (comma or space separated), empty = none
WORKER_DISALLOWED=$(printf '%s' "${COS_WORKER_DISALLOWED_TOOLS:-}" | tr -s ' ' ',')
DISALLOW_FLAG=; [ -z "$WORKER_DISALLOWED" ] || DISALLOW_FLAG="--disallowedTools $(printf '%q' "$WORKER_DISALLOWED") "
EXTRA_FLAGS="${COS_WORKER_CLAUDE_FLAGS:-}"; [ -z "$EXTRA_FLAGS" ] || EXTRA_FLAGS="$EXTRA_FLAGS "
CLAUDE_BIN="${COS_CLAUDE_BIN:-claude}"
EXTRA_PROMPT="${COS_WORKER_PROMPT_EXTRA:-}"; [ -z "$EXTRA_PROMPT" ] || EXTRA_PROMPT="$EXTRA_PROMPT "
# User layer: the user's own standing rules live outside the plugin in $COS_USER_DIR/rules.md (cos-env.sh).
[ ! -f "$COS_USER_DIR/rules.md" ] || EXTRA_PROMPT="${EXTRA_PROMPT}User rules: read $(devault "$COS_USER_DIR/rules.md") in turn 1. "

# Pane colour (cmux): task `color:` override, else cos_pane_color from the optional COS_CMUX_HELPERS file (cos-env.sh
# stubs every pane helper to a no-op when that file is unset, so no helper = plain panes).
PCOLOR=
if [ "$COS_LAUNCHER" = cmux ]; then PCOLOR=$(cos_pane_color "$GOAL" "$TCOLOR_OVR"); fi

LAUNCH="$LAUNCH_DIR/$NAME.sh"
CMD="cd $(printf '%q' "$DIR_SAFE") && bash $(printf '%q' "$LAUNCH"); exec \"\$SHELL\" -l"
ASK_PROMPT="To ask the owner anything (TEST / DECIDE / APPROVE), append an item to the asks: block in the frontmatter of your task file (format: references/orchestration.md → Asks) and name it in a report line; check the charter's Pre-authorized list first — those need no ask. Never edit any other frontmatter key."
CONT_PROMPT=
if [ -n "$CONT" ] && [ "$PLIVE" = 1 ] && [ "$SSTATE" != current ]; then
  CONT_PROMPT="MANDATORY FIRST STEP — you continue worker $CONT, which is still live. Before any build: SendMessage $CONT for its Resume Here (state, open items, next step); never mine a live session's transcript; reconcile with git in every repo it names; post one report line; only then continue. "
elif [ -n "$CONT" ] && [ -z "$PRED" ]; then
  CONT_PROMPT="MANDATORY FIRST STEP — you continue worker $CONT. Before any build: read its session file $(devault "$PSESS") (the Resume Here block first); reconcile with git in every repo it names; post one report line; only then continue. Do NOT mine the old transcript — $([ "$SSTATE" = current ] && echo 'the session file is current' || echo 'none was found; the session file is STALE, so treat git as the truth where they differ'). "
elif [ -n "$CONT" ]; then
  CONT_PROMPT="MANDATORY FIRST STEP — you continue worker $CONT. Before any build: have a sonnet subagent run /agent-ops:session-from-transcript on the old transcript $PRED to write a session file with a Resume Here block; re-read it; reconcile with git in every repo; post one report line; only then continue. "
fi
# Resume: no first prompt — the session already has it; same flags otherwise (cache = model+effort+flags).
LAST_ARGS="--resume $RESUME"
# --resume-prompt: one new turn after the cached context (vault paths aliased like every other argv).
if [ -n "$RESUME_PROMPT" ]; then
  RESUME_PROMPT_SAFE="$RESUME_PROMPT"; [ -z "${COS_VAULT:-}" ] || RESUME_PROMPT_SAFE="${RESUME_PROMPT_SAFE//"$COS_VAULT"/$VAULT_ALIAS}"
  LAST_ARGS="--resume $RESUME $(printf '%q' "$RESUME_PROMPT_SAFE")"
fi
[ -n "$RESUME" ] || PROMPT="$STYLE_PROMPT ${EXTRA_PROMPT}You are a worker session spawned by the chief of staff (role: $ROLE). ${CONT_PROMPT}Your task file: $DEST_CHARTER_SAFE — its body is your charter; do it. Report ONLY by appending lines under \`## Reports\` at the end of that same file (format in the charter → Report protocol). Plain text in this terminal never reaches the chief. When the owner gives you new direction directly in this terminal, follow it and add a one-line note under \`## Reports\` so the chief sees it. $GOAL_PROMPT $ASK_PROMPT ${RULES_PROMPT:+$RULES_PROMPT }$TEARDOWN_PROMPT $TAIL_PROMPT"
[ -n "$RESUME" ] || LAST_ARGS=$(printf '%q' "$PROMPT")
RC_FLAG=; [ "${COS_REMOTE_CONTROL:-0}" = 1 ] && RC_FLAG="--remote-control "
ENV_LINES=
if [ -n "${COS_SPAWN_ENV_CMD:-}" ]; then
  ENV_LINES=$(cat <<L
# COS_SPAWN_ENV_CMD: KEY=VALUE lines exported for this worker (values never printed, logged or stored)
COS_ENV_OUT=\$(bash -c $(printf '%q' "$COS_SPAWN_ENV_CMD \"\$@\"") _ $(printf '%q' "$TASKP") $(printf '%q' "$NAME") 2>/dev/null) || { echo "WARN: COS_SPAWN_ENV_CMD failed — starting without its environment" >&2; COS_ENV_OUT=; }
while IFS= read -r COS_ENV_L; do
  COS_ENV_K="\${COS_ENV_L%%=*}"
  [ "\$COS_ENV_K" != "\$COS_ENV_L" ] && [[ "\$COS_ENV_K" =~ ^[A-Z_][A-Z0-9_]*\$ ]] && export "\$COS_ENV_K=\${COS_ENV_L#*=}"
done <<< "\$COS_ENV_OUT"
unset COS_ENV_OUT COS_ENV_L COS_ENV_K
L
)
fi
CMUX_LINES=
if [ "$COS_LAUNCHER" = cmux ]; then
  CM="${COS_CMUX_BIN:-cmux}"
  CMUX_LINES=$(cat <<L
# cmux status: the hook settings cmux's own claude wrapper injects, handed to the real binary
unset CMUX_CLAUDE_PID CMUX_AGENT_LAUNCH_KIND CMUX_AGENT_LAUNCH_EXECUTABLE CMUX_AGENT_LAUNCH_CWD CMUX_AGENT_LAUNCH_ARGV_B64 CMUX_AGENT_RESUME_LAUNCH CMUX_AGENT_RESTORE_LAUNCH
COS_CMUX_CLI="\${CMUX_BUNDLED_CLI_PATH:-$(printf '%q' "$CM")}"; COS_CMUX_HOOKS=$(printf '%q' "$LAUNCH_DIR/$NAME.cmux-hooks.json")
if [ -n "\${CMUX_SURFACE_ID:-}" ] && [ "\${CMUX_CLAUDE_HOOKS_DISABLED:-}" != 1 ] && command -v "\$COS_CMUX_CLI" >/dev/null 2>&1 \\
   && ( umask 077; CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=2 "\$COS_CMUX_CLI" hooks claude inject-settings </dev/null >"\$COS_CMUX_HOOKS" 2>/dev/null ) \\
   && $(printf '%q' "$COS_PYTHON") -c 'import json,sys; h=json.load(open(sys.argv[1])).get("hooks"); sys.exit(0 if isinstance(h,dict) and h else 1)' "\$COS_CMUX_HOOKS" 2>/dev/null; then
  export CMUX_CLAUDE_PID=\$\$ CMUX_CLAUDE_HOOK_CMUX_BIN="\$COS_CMUX_CLI"
  COS_CMUX_ARGS=(--settings "\$COS_CMUX_HOOKS")
else
  rm -f "\$COS_CMUX_HOOKS"
fi
L
)
fi
LAUNCH_BODY=$(cat <<L
#!/usr/bin/env bash
for v in \$(env | grep -iE "^(CLAUDE|AI_AGENT)" | cut -d= -f1); do unset "\$v"; done
cd $(printf '%q' "$DIR") || { echo $(printf '%q' "cd failed: $DIR"); exit 2; }
COS_CMUX_ARGS=()
$CMUX_LINES
$ENV_LINES
# worker hooks: cos-heartbeat touches the heartbeat file, cos-ck answers the check-in ping
export COS_WORKER=$NAME COS_TAG=$(printf '%q' "$ITAG") COS_REPORT_FILE=$(printf '%q' "$INBOX_SAFE") COS_HEARTBEAT_DIR=$(printf '%q' "$(devault "$COS_DIR")/.heartbeat")
exec $(printf '%q' "$CLAUDE_BIN") "\${COS_CMUX_ARGS[@]+"\${COS_CMUX_ARGS[@]}"}" ${RC_FLAG}-n $(printf '%q' "$NAME") --model $MODEL ${AGENT_FLAG}--effort high ${DISALLOW_FLAG}${EXTRA_FLAGS}$LAST_ARGS
L
)
WS= WS_RULE= WS_CREATE= WS_UUID= WS_PLACEHOLDER= TAB_TITLE="$NAME" FSNAP=
if [ "$COS_LAUNCHER" = cmux ]; then
  command -v "$CM" >/dev/null 2>&1 || [ -x "$CM" ] || { echo "cmux not found (COS_LAUNCHER=cmux) — set COS_LAUNCHER=tmux or print" >&2; exit 1; }
  # Task fields read from the task file (the stamped copy under tasks/, else the --task-file given).
  tval() { local f="$TASKP"; [ -f "$f" ] || f="$TASKF"; [ -n "$f" ] && [ -f "$f" ] || return 0; cos_python "$TPY" get "$f" "$1" 2>/dev/null || true; }
  # Task `title:` → the pane/tab title (default: the worker name). stop.sh finds panes by `where:`, never by title.
  t=$(tval title); [ -z "$t" ] || TAB_TITLE="$t"
  [ "$DRY" = 1 ] || FSNAP=$(cos_focus_snap)   # focus guard: what the owner sees before any workspace or pane create
  TREE=$("$CM" tree --all 2>/dev/null || true)
  # one retry: an empty tree under load makes a titled lookup miss (a duplicate workspace or the wrong fallback)
  [ -n "$TREE" ] || { sleep 1; TREE=$("$CM" tree --all 2>/dev/null || true); }
  ws_live() { [ -z "$TREE" ] || printf '%s\n' "$TREE" | awk -v w="$1" '/ workspace workspace:[0-9]+ / {for(i=1;i<=NF;i++) if ($i==w) f=1} END {exit !f}'; }
  # ws_titled TITLE → the ref of the workspace with that title (case-insensitive), or nothing
  ws_titled() { printf '%s\n' "$TREE" | awk -v t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" 'tolower($0) ~ (" workspace workspace:[0-9]+ \"" t "\"( |$)") {for(i=1;i<=NF;i++) if ($i ~ /^workspace:[0-9]+$/) {print $i; exit}}'; }
  # Target workspace, first hit wins (the spawn.sh header lists the order).
  WS="$WS_ARG"
  if [ -n "$WS" ]; then
    ws_live "$WS" || { echo "refuse: --workspace $WS is not in \`cmux tree --all\` — pass a live workspace:N ref" >&2; exit 2; }
    WS_RULE="--workspace / COS_SPAWN_WORKSPACE"
  fi
  # (b) task `workspace_title:` — the workspace with that title; none → created at launch (never re-read from the tree)
  TWS_TITLE=$(tval workspace_title)
  if [ -z "$WS" ] && [ -n "$TWS_TITLE" ]; then
    WS=$(ws_titled "$TWS_TITLE")
    if [ -n "$WS" ]; then WS_RULE="task workspace_title \"$TWS_TITLE\""; else WS_CREATE="$TWS_TITLE"; fi
  fi
  # (c) a chief task (role chief: task `role: chief`, a *-chief / *-chief-* name, or the CHIEF file's name)
  CHIEF_WS_TITLE="${COS_CHIEF_WORKSPACE_TITLE:-CHIEF}"
  if [ -z "$WS" ] && [ -z "$WS_CREATE" ] && [ "$ROLE" = chief ]; then
    WS=$(ws_titled "$CHIEF_WS_TITLE")
    if [ -n "$WS" ]; then WS_RULE="chief task → workspace \"$CHIEF_WS_TITLE\""
    else echo "WARN: chief task but no workspace titled \"$CHIEF_WS_TITLE\" (COS_CHIEF_WORKSPACE_TITLE) — using the next rule" >&2; fi
  fi
  # (d) COS_CMUX_WORKSPACE_ROUTES: `;`-separated PATTERN=TITLE; PATTERN is a case-insensitive shell glob matched against
  # "<name> <category> <lane>"; first match wins; the workspace must already exist (never created here).
  if [ -z "$WS" ] && [ -z "$WS_CREATE" ] && [ -n "${COS_CMUX_WORKSPACE_ROUTES:-}" ]; then
    RSUBJ=$(printf '%s %s %s' "$NAME" "$(tval category)" "$(tval lane)" | tr '[:upper:]' '[:lower:]')
    IFS=';' read -r -a _routes <<< "$COS_CMUX_WORKSPACE_ROUTES"
    for r in "${_routes[@]+"${_routes[@]}"}"; do
      case "$r" in *=*) ;; *) continue;; esac
      rp=$(printf '%s' "${r%%=*}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
      rt=$(printf '%s' "${r#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -n "$rp" ] && [ -n "$rt" ] || continue
      # shellcheck disable=SC2254  # the pattern is a glob on purpose
      case "$RSUBJ" in $rp)
        WS=$(ws_titled "$rt")
        if [ -n "$WS" ]; then WS_RULE="route $rp → workspace \"$rt\""
        else echo "WARN: route $rp matches but no workspace titled \"$rt\" (COS_CMUX_WORKSPACE_ROUTES; never created) — using the next rule" >&2; fi
        break;;
      esac
    done
  fi
  # (e) the config pin if it still exists, then the workspace titled $COS_CMUX_WORKSPACE_TITLE (default "chief")
  if [ -z "$WS" ] && [ -n "${COS_CMUX_WORKSPACE:-}" ]; then
    if ws_live "$COS_CMUX_WORKSPACE"; then WS="$COS_CMUX_WORKSPACE" WS_RULE="COS_CMUX_WORKSPACE pin"
    else echo "WARN: COS_CMUX_WORKSPACE=$COS_CMUX_WORKSPACE is stale — falling back to the workspace titled \"${COS_CMUX_WORKSPACE_TITLE:-chief}\"" >&2; fi
  fi
  if [ -z "$WS" ]; then WS=$(ws_titled "${COS_CMUX_WORKSPACE_TITLE:-chief}"); [ -z "$WS" ] || WS_RULE="workspace titled \"${COS_CMUX_WORKSPACE_TITLE:-chief}\""; fi
fi
# cmux + tmux (COS_CMUX_TMUX=1): claude lives in tmux session NAME; the pane command only attaches.
CTMUX=0 TSESS_CMD=
if [ "$COS_LAUNCHER" = cmux ] && [ "${COS_CMUX_TMUX:-0}" = 1 ]; then
  CTMUX=1
  if cos_has_tmux; then
    ! cos_tmux has-session -t "=$NAME" 2>/dev/null \
      || { echo "refuse: tmux session $NAME already exists${COS_TMUX_SOCKET:+ (socket $COS_TMUX_SOCKET)} — stop it first (stop.sh $NAME) or pick another name" >&2; exit 2; }
  elif [ "$DRY" = 0 ]; then echo "tmux not found (COS_CMUX_TMUX=1) — install tmux, set COS_TMUX_BIN, or set COS_CMUX_TMUX=0" >&2; exit 1
  else echo "WARN: tmux not found (COS_CMUX_TMUX=1) — a real spawn would exit 1" >&2; fi
  TSESS_CMD="unset CMUX_SURFACE_ID CMUX_WORKSPACE_ID CMUX_PANEL_ID CMUX_TAB_ID; bash $(printf '%q' "$LAUNCH"); exec \"\$SHELL\" -l"
  # quoted '=NAME': cmux types the command into an interactive shell, where a bare =word can expand (zsh)
  CMD="cd $(printf '%q' "$DIR_SAFE") && $(cos_tmux_cmd) attach -t '=$NAME'; exec \"\$SHELL\" -l"
fi
wt_shell_args() {   # one arg per line: the shell Windows Terminal opens for this worker (launch script, then a login shell)
  if [ "${COS_WSL:-0}" = 1 ]; then printf '%s\n' wsl.exe -d "${WSL_DISTRO_NAME:-}" -- bash -lc "bash $(printf '%q' "$LAUNCH") || true && exec bash -l"
  else printf '%s\n' "$( (cygpath -w "$(command -v bash)" 2>/dev/null) || command -v bash)" -lc "bash $(printf '%q' "$LAUNCH") || true && exec bash -l"; fi
}
TMUX_SESSION="${COS_TMUX_SESSION:-agent-ops}"
if [ "$DRY" = 1 ]; then
  if [ -n "$RESUME" ]; then
    echo "DRY-RUN resume: session $RESUME · transcript $RTRANS"
    echo "DRY-RUN resume: model $MODEL ($MODEL_SRC) · effort high · agent ${AGENT:-none} · $([ -n "$RESUME_PROMPT" ] && echo "first prompt (--resume-prompt): $RESUME_PROMPT" || echo "no first prompt")"
  else dry_goal; echo "DRY-RUN role: $ROLE · first prompt ${#PROMPT} chars"; fi
  case "$COS_LAUNCHER" in
    cmux)
      [ "$CTMUX" = 0 ] || printf 'DRY-RUN tmux (COS_CMUX_TMUX=1): %s new-session -d -s %q -c %q %q\n' "$(cos_tmux_cmd)" "$NAME" "$DIR" "$TSESS_CMD"
      if [ -n "$WS_CREATE" ]; then echo "DRY-RUN workspace: would create \"$WS_CREATE\" (task workspace_title)$([ -n "$WS" ] && echo " · if that fails: $WS ($WS_RULE)")"
        printf 'DRY-RUN: %q --json --id-format both workspace create --name %q --cwd %q --focus false\n' "$CM" "$WS_CREATE" "$DIR"
        printf 'DRY-RUN: %q new-pane --type terminal --workspace <created ref> --direction right --command %q --focus false; then close the placeholder surface\n' "$CM" "$CMD"
      elif [ -n "$WS" ]; then echo "DRY-RUN workspace: $WS ($WS_RULE)"
        GRID_PLAN=; [ "${COS_LAYOUT:-row}" = grid ] && GRID_PLAN=$(cos_grid_plan "$WS")
        if [ -n "$GRID_PLAN" ]; then printf 'DRY-RUN: %q new-split %s --surface %s --workspace %q --command %q --focus false\n' "$CM" "${GRID_PLAN#* }" "${GRID_PLAN% *}" "$WS" "$CMD"
        else printf 'DRY-RUN: %q new-pane --type terminal --workspace %q --direction right --command %q --focus false\n' "$CM" "$WS" "$CMD"; fi
      else echo "DRY-RUN workspace: none (no rule matched) — fallback: a new workspace named after the worker"
        printf 'DRY-RUN (no chief workspace, fallback): %q workspace create --name %q --cwd %q --command %q --focus false\n' "$CM" "$NAME" "$DIR" "$CMD"; fi
      echo "DRY-RUN tab title: $TAB_TITLE"
      [ -z "$PCOLOR" ] || printf 'DRY-RUN: then %q send %q to the new pane\n' "$CM" "/color $PCOLOR"
      [ "$CTMUX" = 0 ] || echo "DRY-RUN where: cmux ws<N>/surface:<M>/tmux:$NAME (the pane only attaches; stop.sh kills the session)";;
    wt) printf 'DRY-RUN: %s -w 0 new-tab --title %q %s\n' "$(cos_wt_bin 2>/dev/null || echo wt.exe)" "$NAME" "$(wt_shell_args | tr '\n' ' ')";;
    tmux) printf 'DRY-RUN: tmux%s new-window -d -t %q -n %q -c %q %q\n' "${COS_TMUX_SOCKET:+ (socket $COS_TMUX_SOCKET)}" "$TMUX_SESSION" "$NAME" "$DIR" "$CMD";;
    *) printf 'DRY-RUN print launcher: run in a new terminal:\n  %s\n' "$CMD"
       echo "DRY-RUN claude command: $(printf '%s\n' "$LAUNCH_BODY" | grep '^exec ' | cut -c6-)";;
  esac
  echo "DRY-RUN task file: $TASKP"
  echo "DRY-RUN launch script $LAUNCH:"; printf '%s\n' "$LAUNCH_BODY" | sed 's/^/  /'
  exit 0
fi
mkdir -p "$LAUNCH_DIR"
if [ -n "$RESUME" ]; then cos_python "$TPY" report "$TASKP" "status: RESUMED $STAMP session $RESUME (spawn.sh --resume: model $MODEL, effort high)"
else cos_python "$TPY" report "$TASKP" "status: STARTED $STAMP"; fi
printf '%s\n' "$LAUNCH_BODY" > "$LAUNCH"
chmod +x "$LAUNCH"
case "$COS_LAUNCHER" in
  cmux)
    if [ "$CTMUX" = 1 ]; then
      cos_tmux new-session -d -s "$NAME" -c "$DIR" "$TSESS_CMD" || { echo "tmux new-session $NAME failed" >&2; exit 1; }
    fi
    if [ -n "$WS_CREATE" ]; then
      # task workspace_title, first use: the target is the ref + placeholder surface that `workspace create` RETURNS —
      # never a tree re-read by title (a just-created workspace can be missing from it). Placeholder closed below.
      IFS='|' read -r WS_UUID NEWWS WS_PLACEHOLDER < <(CMUX_QUIET=1 "$CM" --json --id-format both workspace create --name "$WS_CREATE" --cwd "$DIR" --focus false 2>/dev/null \
        | cos_python -c 'import json,sys; j=json.load(sys.stdin); print("|".join(j.get(k) or "" for k in ("workspace_id", "workspace_ref", "surface_id")))' 2>/dev/null || true) || true
      case "${NEWWS:-}" in
        workspace:[0-9]*) WS="$NEWWS" WS_RULE="task workspace_title \"$WS_CREATE\" (created)";;
        *) WS_UUID= WS_PLACEHOLDER=
           echo "WARN: could not create workspace \"$WS_CREATE\" (task workspace_title) — using ${WS:-a new workspace named after the worker}${WS_RULE:+ ($WS_RULE)}" >&2;;
      esac
    fi
    if [ -n "$WS" ]; then
      # Grid decided BEFORE the pane exists; never move a surface afterwards (that wipes scrollback).
      GRID_PLAN=; [ "${COS_LAYOUT:-row}" = grid ] && GRID_PLAN=$(cos_grid_plan "$WS"); out=
      if [ -n "$GRID_PLAN" ]; then
        out=$("$CM" new-split "${GRID_PLAN#* }" --surface "${GRID_PLAN% *}" --workspace "$WS" --command "$CMD" --focus false 2>&1) \
          || { echo "WARN: new-split ${GRID_PLAN#* } of ${GRID_PLAN% *} failed ($out) — using new-pane default" >&2; out=; }
      fi
      printf '%s' "$out" | grep -qE 'surface:[0-9]+' \
        || out=$("$CM" new-pane --type terminal --workspace "$WS" --direction right --command "$CMD" --focus false)
      SURF=$(printf '%s\n' "$out" | grep -oE 'surface:[0-9]+' | head -1)
      [ -n "$SURF" ] || { echo "cmux new-pane gave no surface: $out" >&2
        [ "$CTMUX" = 0 ] || echo "note: the worker still runs in tmux session $NAME — attach: $(cos_tmux_cmd) attach -t '=$NAME'" >&2; exit 1; }
      "$CM" tab-action --action rename --workspace "$WS" --surface "$SURF" --title "$TAB_TITLE" >/dev/null 2>&1 \
        || echo "WARN: could not rename tab $SURF to $TAB_TITLE" >&2
      WHERE="cmux ws${WS#workspace:}/$SURF"
      # the created workspace's placeholder shell goes only now that the worker pane exists
      for t in $WS_PLACEHOLDER; do CMUX_QUIET=1 "$CM" close-surface --workspace "$WS_UUID" --surface "$t" >/dev/null 2>&1 || true; done
      [ -z "$WS_PLACEHOLDER" ] || cos_focus_keep "$FSNAP" "$WS" "$SURF" close-placeholder
      [ -z "$PCOLOR" ] || cos_send_pane_color "$CM" "$WS" "$SURF" "$PCOLOR" "$FSNAP"
      cos_focus_keep "$FSNAP" "$WS" "$SURF" new-pane
      cos_equalize "$WS"
      cos_focus_keep "$FSNAP" "$WS" "$SURF" equalize
    else
      echo "WARN: no workspace rule matched and no cmux workspace titled \"${COS_CMUX_WORKSPACE_TITLE:-chief}\" — falling back to a NEW workspace" >&2
      "$CM" workspace create --name "$NAME" --cwd "$DIR" --command "$CMD" --focus false
      WHERE=cmux
    fi
    [ "$CTMUX" = 0 ] || WHERE="$WHERE/tmux:$NAME";;
  tmux)
    cos_has_tmux || { echo "tmux not found (COS_LAUNCHER=tmux) — install tmux or set COS_LAUNCHER=print" >&2; exit 1; }
    cos_tmux has-session -t "$TMUX_SESSION" 2>/dev/null || cos_tmux new-session -d -s "$TMUX_SESSION" -n chief
    cos_tmux new-window -d -t "$TMUX_SESSION" -n "$NAME" -c "$DIR" "$CMD"
    WHERE="tmux $TMUX_SESSION:$NAME";;
  wt)
    WTB=$(cos_wt_bin) || { echo "wt.exe not found (COS_LAUNCHER=wt) — install Windows Terminal or set COS_LAUNCHER=print" >&2; exit 1; }
    WTARGS=(); while IFS= read -r a; do WTARGS+=("$a"); done < <(wt_shell_args)
    "$WTB" -w 0 new-tab --title "$NAME" "${WTARGS[@]}" >/dev/null 2>&1 \
      || { echo "wt.exe new-tab failed — run it yourself: bash -l $LAUNCH" >&2; exit 1; }
    WHERE="wt $NAME";;
  *)
    echo "print launcher — open a terminal and run:"
    echo "  $CMD"
    echo "claude command (inside $LAUNCH): $(printf '%s\n' "$LAUNCH_BODY" | grep '^exec ' | cut -c6-)"
    echo "task file: $TASKP"
    WHERE="print (owner launches)";;
esac

# The task file is the ledger row (no LEDGER.md append).
if [ -n "$RESUME" ]; then cos_python "$TPY" set "$TASKP" status running where "$WHERE" resumed "$STAMP"
  echo "OK resumed $NAME session $RESUME ($WHERE, $MODEL, effort high${AGENT:+, agent $AGENT}) — task file: $TASKP"; exit 0; fi
cos_python "$TPY" set "$TASKP" status running where "$WHERE" started "$STAMP" model "$MODEL" role "$ROLE"
# Predecessor superseded — only now that the successor is running.
if [ -n "$CONT" ]; then
  if [ -f "$COS_DIR/tasks/$CONT.md" ]; then
    if [ "$PLIVE" = 1 ]; then cos_python "$TPY" set "$COS_DIR/tasks/$CONT.md" handoff "superseded by $NAME"
      echo "task $CONT → handoff: superseded by $NAME (live: status kept until its HANDOFF line)" >&2
    else cos_python "$TPY" set "$COS_DIR/tasks/$CONT.md" status stopped handoff "superseded by $NAME" closed "$STAMP"
      echo "task $CONT → status: stopped, handoff: superseded by $NAME" >&2; fi
  elif [ -f "$COS_DIR/missions/$CONT.yaml" ]; then mset "$COS_DIR/missions/$CONT.yaml" status stopped handoff "superseded by $NAME"
    echo "mission $CONT → status: stopped, handoff: superseded by $NAME" >&2
  else echo "WARN: no missions/$CONT.yaml to mark superseded" >&2; fi
  "$HERE/sessions.sh" --tsv 2>/dev/null | awk -F'\t' -v n="$CONT" '$1=="live" && $2==n {f=1} END {exit !f}' \
    && echo "WARN: $CONT still has a live session — stop it (stop.sh $CONT) once $NAME has posted its first inbox line" >&2
fi
echo "OK spawned $NAME ($WHERE, $MODEL, role $ROLE${AGENT:+, agent $AGENT}, parent [$GTAG]) — task goal: $TGOAL — task file: $TASKP"
