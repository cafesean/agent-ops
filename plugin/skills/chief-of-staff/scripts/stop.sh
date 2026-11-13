#!/usr/bin/env bash
# Stop a worker the chief spawned: kill its claude pid, drop its registry file, close its pane/window
# (task `where:` — `tmux <session>:<name>`, or cmux `ws<N>/surface:<M>`; never the chief's own) and mark the
# task closed. A cmux worker spawned with COS_CMUX_TMUX=1 (where: `…/tmux:NAME`) runs in tmux session NAME and its
# pane only attaches: stop.sh kills that session (cos_tmux: $COS_TMUX_BIN on $COS_TMUX_SOCKET) and then closes the
# pane as usual; the subagent gate reads the screen with tmux capture-pane of that session.
# Only for workers the chief spawned — never the owner's own sessions.
#   stop.sh NAME [STATUS] [--force] [--dry-run]     STATUS defaults to STOPPED
#   --dry-run: run every gate and mark the task closed, but kill no pid and close no pane/window.
# Session-log gate (any STATUS): the task's report since its last STARTED needs a line containing "session:" or
#   "sessions/" (the worker wrote its session log) — else refuse (exit 4) unless --force.
# Open-ask gate: a task with an open ask to the owner is waiting on them, not done — refuse (exit 5) unless the
#   task is `status: parked` (worker wrote its handoff) or --force.
# Ownership gate: a machine stops only workers with its own prefix (cos-env.sh cos_own) — exit 6.
# DONE gate: STATUS=DONE refuses (exit 7) unless the report since the last STARTED has
#   - always: a `session:` line (session log) and a `teardown:` line (worktrees removed/kept, servers stopped)
#   - COS_REQUIRE_REFS=1: a `refs:` line (reference docs updated, or "none")
#   - Jira add-on on (COS_JIRA_BASE set): a `jira:` tag
#   Only a `status: STARTED` report line opens the window (a quoted WARN holding the word does not).
# HANDOFF gate: STATUS=HANDOFF refuses (exit 7) without a `refs:` line since the last STARTED (handover = wind-down
#   too); any other stop only WARNs when a HANDOFF report line has no `refs:` after it.
# Owner-typed gate: the owner typed a turn in the session < COS_REAP_IDLE_MIN (60) min ago (lib/lastturn.py
#   --human-min) → it is their live conversation — exit 8 unless --force.
# Worktree gate: DONE/STOPPED/PARKED/HANDOFF refuse (exit 9) while a git worktree stamped as NAME's by
#   hooks/worktree-owner.py is still there and not locked with a reason; a dirty one must be committed + pushed first.
#   Sources: $COS_DIR/.worktrees/NAME (hook registry) + <root>/.git/worktrees/*/cos-owner and
#   <root>/*/.git/worktrees/*/cos-owner for each root in COS_WORKTREE_ROOTS (colon list, default none). Fails open.
# Subagent gate: before killing, read the worker's screen (tmux capture-pane for `tmux <target>` or `…/tmux:NAME`,
#   cmux read-screen for `ws<N>/surface:<M>`, else the cmux surface whose tab title = NAME). Refuse (exit 7) unless
#   --force when the screen has a running-task line `◯ <text> <elapsed>` (elapsed `3m 11s` or `12s ·`). Footer markers `← N agent(s)` /
#   `· N shell(s)` are ignored (they persist after agents finish). Screen unreadable = WARN and continue.
# Close: sets the task `status: done|failed|stopped|parked` + a `closed:` stamp, so no live task outlives its worker.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"
FORCE=0; DRY=0; ARGS=()
for a in "$@"; do case "$a" in --force) FORCE=1;; --dry-run) DRY=1;; *) ARGS+=("$a");; esac; done
NAME="${ARGS[0]:-}"; [ -n "$NAME" ] || { echo "usage: stop.sh NAME [STATUS] [--force] [--dry-run]" >&2; exit 2; }
STATUS="${ARGS[1]:-STOPPED}"
TPY="$HERE/lib/tasks.py"
TFILE="$COS_DIR/tasks/$NAME.md"; [ -f "$TFILE" ] || TFILE=
[ -n "$TFILE" ] || grep -q "| $NAME |" "$COS_DIR/LEDGER.md" 2>/dev/null || { echo "refuse: $NAME is not a chief-spawned worker (no tasks/$NAME.md, not in LEDGER)" >&2; exit 3; }
where_of() { if [ -n "$TFILE" ]; then cos_python "$TPY" get "$TFILE" where; else grep "| $NAME |" "$COS_DIR/LEDGER.md" | tail -1 | awk -F'|' '{print $4}' | xargs; fi; }
cos_own "$NAME" || { echo "refuse: $NAME is not this machine's worker (prefix ${COS_PREFIX}-, host ${COS_HOST_PREFIX}) — stop it on its own machine" >&2
  [ "$FORCE" = 1 ] || exit 6; echo "--force: stopping a foreign-prefix worker" >&2; }
# Owner-typed gate — exit 8 unless --force.
HMIN=$(cos_python "$HERE/lib/lastturn.py" --human-min "$NAME" 2>/dev/null || echo -1)
if [ "${HMIN:--1}" -ge 0 ] 2>/dev/null && [ "$HMIN" -lt "${COS_REAP_IDLE_MIN:-60}" ]; then
  echo "WARN: the owner typed in $NAME ${HMIN} min ago — it is their live conversation, not done." >&2
  [ "$FORCE" = 1 ] || { echo "refuse: wait ${COS_REAP_IDLE_MIN:-60} min after the owner's last turn, or the owner says finished (--force)" >&2; exit 8; }
fi
INBOX="${TFILE:-$COS_DIR/inbox/$NAME.md}"
MFILE="$COS_DIR/missions/$NAME.yaml"
if [ -n "$TFILE" ]; then   # task file: open asks live in its frontmatter
  OPEN=$(cos_python -c 'import sys; sys.path.insert(0, sys.argv[1]); import tasks; fm, _ = tasks.read(sys.argv[2])
import re
# parked = the worker wrote its handoff: task `status: parked`, or (stop.sh NAME PARKED) its latest report status is PARKED
L = tasks.reports(_).split("\n"); st = [m.group(1) for m in (re.search(r"status:\s*\**\s*(STARTED|RESUMED|WORKING|BLOCKED|DONE|FAILED|PARKED|STOPPED|HANDOFF)\b", l) for l in L) if m]
parked = str(fm.get("status")) == "parked" or (sys.argv[3] == "PARKED" and bool(st) and st[-1] == "PARKED")
print(0 if parked else sum(1 for a in fm.get("asks") or [] if isinstance(a, dict) and str(a.get("status") or "open").lower() == "open"))' "$HERE/lib" "$TFILE" "$STATUS")
  if [ "${OPEN:-0}" -gt 0 ]; then
    echo "WARN: $NAME has $OPEN open ask(s) to the owner in $TFILE — it is waiting on them, not done. Park it (handoff + status: parked) instead" >&2
    [ "$FORCE" = 1 ] || { echo "refuse: re-run with --force to stop $NAME with an open ask" >&2; exit 5; }
  fi
  MFILE=/nonexistent
fi
if [ "$STATUS" = DONE ]; then
  MISSING=$(cos_python - "$INBOX" "${COS_JIRA_BASE:-}" "${COS_REQUIRE_REFS:-0}" <<'PY'
import re, sys, os
p, jira_on, refs_on = sys.argv[1], bool(sys.argv[2]), sys.argv[3] == "1"
lines = open(p, encoding="utf-8", errors="ignore").read().split("\n") if os.path.exists(p) else []
start = max([i for i, l in enumerate(lines) if re.search(r"status:\s*\**\s*STARTED\b", l)] or [0])
blk = "\n".join(lines[start:])
need = []
if not re.search(r"session:|sessions/", blk): need.append("session:")
if not re.search(r"\bteardown:", blk): need.append("teardown:")
if refs_on and not re.search(r"(?<![\w-])refs:\s*\S", blk): need.append("refs:")   # also inline "· refs: …"
if jira_on and not re.search(r"\bjira:\s*\S", blk): need.append("jira:")
print(" ".join(need))
PY
)
  if [ -n "$MISSING" ]; then
    echo "WARN: $NAME reports DONE without: $MISSING — required in its task report since the last STARTED" >&2
    [ "$FORCE" = 1 ] || { echo "refuse: ask $NAME to add them, or re-run with --force" >&2; exit 7; }
  fi
fi
HMISS=$(cos_python - "$INBOX" "$STATUS" <<'PYH'
import re, sys, os
p = sys.argv[1]
L = open(p, encoding="utf-8", errors="ignore").read().split("\n") if os.path.exists(p) else []
start = max([i for i, l in enumerate(L) if re.search(r"status:\s*\**\s*STARTED\b", l)] or [0])
h = [i for i, l in enumerate(L) if i >= start and re.search(r"status:\s*\**\s*HANDOFF\b", l)]
frm = h[-1] if h else start
want = sys.argv[2] == "HANDOFF" or bool(h)
print("refs:" if want and not re.search(r"(?<![\w-])refs:\s*\S", "\n".join(L[frm:])) else "")
PYH
)
if [ -n "$HMISS" ]; then
  echo "WARN: $NAME handed over without refs: — update the reference docs and add 'refs: <repo> <hash>' or 'refs: none (why)' to the HANDOFF line" >&2
  [ "$STATUS" != HANDOFF ] || [ "$FORCE" = 1 ] || { echo "refuse: ask $NAME to add refs:, or re-run with --force" >&2; exit 7; }
fi
if [ -f "$MFILE" ]; then
  OPEN=$(cos_python - "$MFILE" <<'PY'
import re, sys
top, parked, items = None, False, []
for raw in open(sys.argv[1], encoding="utf-8", errors="ignore"):
    line = raw.split(" #")[0].rstrip()
    m = re.match(r"([A-Za-z_][\w-]*):\s*(.*)", line)
    if m:
        top = m.group(1)
        if top == "status" and m.group(2).strip().strip("\"'") == "parked": parked = True
        continue
    if top != "asks": continue
    b = line.strip()
    if b.startswith("- "): items.append({}); b = b[2:].strip()
    k = re.match(r"([A-Za-z_][\w-]*):\s*(.*)", b)
    if k and items: items[-1][k.group(1)] = k.group(2).strip().strip("\"'")
n = sum(1 for i in items if i.get("status", "open").lower() == "open")
print(0 if parked else n)
PY
)
  if [ "${OPEN:-0}" -gt 0 ]; then
    echo "WARN: $NAME has $OPEN open ask(s) to the owner in $MFILE — it is waiting on them, not done. Park it (handoff + mission status: parked) instead" >&2
    [ "$FORCE" = 1 ] || { echo "refuse: re-run with --force to stop $NAME with an open ask" >&2; exit 5; }
  fi
fi
if ! { [ -f "$INBOX" ] && awk '/status:[[:space:]]*\**[[:space:]]*STARTED/ {seen=0; next} /session:|sessions\// {seen=1} END {exit !seen}' "$INBOX"; }; then
  echo "WARN: $NAME inbox has no session log (no \"session:\" or \"sessions/\" line since its last STARTED) — ask it to run /agent-ops:session-update first" >&2
  [ "$FORCE" = 1 ] || { echo "refuse: re-run with --force to stop $NAME without a session log" >&2; exit 4; }
  echo "--force: stopping $NAME without a session log" >&2
fi
# Worktree gate (exit 9) — read from git, not from report text. Any read error fails open.
case "$STATUS" in DONE|STOPPED|PARKED|HANDOFF)
  WTLEFT=$(cos_python - "$NAME" "$COS_DIR/.worktrees/$NAME" "${COS_WORKTREE_ROOTS:-}" <<'PYW' 2>/dev/null || true
import glob, os, subprocess, sys
name, reg, roots = sys.argv[1:]
dirs = set()
try: dirs |= {l.strip() for l in open(reg) if l.strip()}
except OSError: pass
for root in [r for r in roots.split(":") if r]:
    dirs |= {os.path.dirname(f) for f in glob.glob(os.path.join(root, "*", ".git", "worktrees", "*", "cos-owner"))}
    dirs |= {os.path.dirname(f) for f in glob.glob(os.path.join(root, ".git", "worktrees", "*", "cos-owner"))}
for d in sorted(dirs):
    try:
        if open(os.path.join(d, "cos-owner")).readline().strip() != name: continue
        wt = os.path.dirname(open(os.path.join(d, "gitdir")).read().strip())
    except OSError: continue   # admin dir gone = worktree removed
    if not os.path.isdir(wt): continue   # dir gone, only a prunable admin entry left
    lk = os.path.join(d, "locked")
    if os.path.exists(lk) and open(lk).read().strip(): continue   # locked with a reason = deliberate keep
    st = subprocess.run(["git", "-C", wt, "status", "--porcelain"], capture_output=True, text=True, timeout=20)
    if st.returncode != 0: continue
    n = len(st.stdout.splitlines())
    print(f"  {wt}  " + (f"DIRTY ({n} files): commit and push to its branch first, then git worktree remove" if n
                         else "clean: git worktree remove it, or git worktree lock --reason '<why> (owner " + name + ")'"))
PYW
)
  if [ -n "$WTLEFT" ]; then
    echo "WARN: $NAME leaves git worktrees it created (owner stamp) — remove each, or lock it with a reason:" >&2
    printf '%s\n' "$WTLEFT" >&2
    [ "$FORCE" = 1 ] || { echo "refuse: tear down these worktrees first, or re-run with --force" >&2; exit 9; }
    echo "--force: stopping $NAME with its worktrees left" >&2
  fi;;
esac
# Subagent gate (exit 7): never kill a worker that still runs subagents/background tasks (their context is lost).
CMG="${COS_CMUX_BIN:-cmux}"   # COS_CMUX_BIN: tests point it at a fake
GW=$(where_of 2>/dev/null || true)
RUNNING='◯ .*([0-9]+m [0-9]+s|[0-9]+s ·)'
subagent_check() {  # subagent_check SCREEN LABEL
  if [ -z "$1" ]; then echo "WARN: could not read $2 — cannot check for running subagents; continuing" >&2
  elif printf '%s' "$1" | grep -Eq "$RUNNING"; then
    echo "WARN: $NAME's $2 shows running subagents/background tasks — killing it wastes their context" >&2
    [ "$FORCE" = 1 ] || { echo "refuse: wait until it runs no subagents and has handed over (Resume Here + HANDOFF, idle), or re-run with --force" >&2; exit 7; }
    echo "--force: stopping $NAME with subagents running" >&2
  fi
}
if [[ "$GW" == "wt "* ]]; then :
elif [[ "$GW" =~ ^tmux\ (.+)$ ]]; then
  TGT="${BASH_REMATCH[1]}"
  if cos_has_tmux; then subagent_check "$(cos_tmux capture-pane -p -t "$TGT" 2>/dev/null || true)" "tmux pane $TGT"; fi
elif [[ "$GW" =~ /tmux:([^/[:space:]]+)$ ]]; then
  TSN="${BASH_REMATCH[1]}"
  if cos_has_tmux; then subagent_check "$(cos_tmux capture-pane -p -t "=$TSN:" 2>/dev/null || true)" "tmux session $TSN"; fi
elif [ "$COS_LAUNCHER" = cmux ] && command -v "$CMG" >/dev/null 2>&1; then
  GSURF=; GWS=
  if [[ "$GW" =~ ws([0-9]+)/(surface:[0-9]+) ]]; then GWS="workspace:${BASH_REMATCH[1]}"; GSURF="${BASH_REMATCH[2]}"
  else GSURF=$("$CMG" tree --all 2>/dev/null | awk -v t="\"$NAME\"" '{for(i=1;i<=NF;i++) if ($i ~ /^surface:[0-9]+$/ && $(i+1)==t) {print $i; exit}}' || true); fi
  if [ -z "$GSURF" ]; then echo "WARN: $NAME's cmux surface not found — cannot check for running subagents; continuing" >&2
  else subagent_check "$("$CMG" read-screen ${GWS:+--workspace "$GWS"} --surface "$GSURF" 2>/dev/null || true)" "pane $GSURF"; fi
fi
# Transcript subagent gate (exit 7): a subagent writes its own .jsonl under <session>/subagents/ while it runs. A
# subagent written in the last 10 min = running. Checked against the transcript, not the pane, so a lead that
# hands over with subagents still going is not stopped; it stays up as a relay until they report.
SUB_SID=
for f in "$HOME"/.claude/sessions/*.json; do
  [ -e "$f" ] || continue
  if cos_python -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get('name')==sys.argv[2] else 1)" "$f" "$NAME" 2>/dev/null; then
    SUB_SID=$(cos_python -c "import json,sys;print(json.load(open(sys.argv[1])).get('sessionId',''))" "$f" 2>/dev/null || true); break
  fi
done
if [ -n "$SUB_SID" ]; then
  RUN_SUBS=$(find "$HOME"/.claude/projects -path "*/$SUB_SID/subagents/*.jsonl" -mmin -10 2>/dev/null | head -3)
  if [ -n "$RUN_SUBS" ]; then
    echo "WARN: $NAME has subagents written in the last 10 min (transcript) — stopping it ends their work" >&2
    [ "$FORCE" = 1 ] || { echo "refuse: subagents still running. The lead stays up as a relay: forward each result to its successor and task file, start no new work, write 'subagents: 0 running' when they finish, then stop. Or re-run with --force." >&2; exit 7; }
    echo "--force: stopping $NAME with subagents running" >&2
  fi
fi
for f in "$HOME"/.claude/sessions/*.json; do
  [ -e "$f" ] || continue
  [ "$DRY" = 0 ] || { cos_python -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get('name')==sys.argv[2] else 1)" "$f" "$NAME" 2>/dev/null && echo "DRY-RUN: would kill pid $(basename "$f" .json)"; continue; }
  if cos_python -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get('name')==sys.argv[2] else 1)" "$f" "$NAME" 2>/dev/null; then
    pid=$(basename "$f" .json); kill -9 "$pid" 2>/dev/null || { [ "$COS_OS" = windows ] && taskkill //PID "$pid" //F >/dev/null 2>&1; } || true; rm -f "$f" "$HOME/.claude/sessions/$pid".*.key; echo "killed pid $pid"
  fi
done
# cmux + tmux worker (where: …/tmux:NAME): kill its tmux session first (claude gets SIGHUP), then the pane below.
TSESS=; [[ "$GW" =~ /tmux:([^/[:space:]]+)$ ]] && TSESS="${BASH_REMATCH[1]}"
if [ -n "$TSESS" ]; then
  if [ "$DRY" = 1 ]; then echo "DRY-RUN: would kill tmux session $TSESS ($(cos_tmux_cmd) kill-session -t '=$TSESS')"
  elif cos_has_tmux && cos_tmux kill-session -t "=$TSESS" 2>/dev/null; then echo "killed tmux session $TSESS"
  else echo "WARN: no tmux session $TSESS (already gone?)" >&2; fi
fi
if [ "$DRY" = 1 ]; then echo "DRY-RUN: would close $NAME's pane/window ($(where_of))"
elif where_of | grep -qE '^wt '; then
  echo "note: Windows Terminal tab \"$NAME\" stays open (wt.exe cannot close tabs) — close it by hand"
elif where_of | grep -qE '^tmux '; then
  tw=$(where_of | sed -E 's/^tmux //')
  cos_has_tmux && cos_tmux kill-window -t "$tw" 2>/dev/null && echo "closed tmux window $tw" || echo "WARN: no tmux window $tw (already gone?)" >&2
fi
CM="${COS_CMUX_BIN:-cmux}"   # COS_CMUX_BIN: tests point it at a fake
if [ "$DRY" = 0 ] && [ "$COS_LAUNCHER" = cmux ] && command -v "$CM" >/dev/null 2>&1; then
  where=$(where_of)
  if [[ "$where" =~ ws([0-9]+)/(surface:[0-9]+) ]]; then
    ws="workspace:${BASH_REMATCH[1]}"; surf="${BASH_REMATCH[2]}"
    if "$CM" close-surface --workspace "$ws" --surface "$surf" >/dev/null 2>&1; then
      echo "closed $surf in $ws"
      # Every pane close re-equalizes that workspace (cmux has no pane hook).
      cos_equalize "$ws"   # no-op unless COS_CMUX_HELPERS defines it
    fi
  else
    # legacy worker spawned as its own workspace: close it only if its title is exactly NAME and it is not the chief's
    ws=$("$CM" tree --all 2>/dev/null | awk -v t="\"$NAME\"" '$0 ~ / workspace workspace:[0-9]+ / {for(i=1;i<=NF;i++) if ($i ~ /^workspace:[0-9]+$/ && $(i+1)==t) {print $i; exit}}')
    if [ -n "$ws" ] && [ "$NAME" != chief ] && [ "$ws" != "${COS_CMUX_WORKSPACE:-}" ]; then
      "$CM" close-workspace --workspace "$ws" >/dev/null 2>&1 && echo "closed $ws"
    fi
  fi
fi
if [ -n "$TFILE" ]; then
  TST=stopped; [ "$STATUS" != DONE ] || TST=done; [ "$STATUS" != FAILED ] || TST=failed; [ "$STATUS" != PARKED ] || TST=parked
  cos_python "$TPY" set "$TFILE" status "$TST" closed "$(date '+%Y-%m-%d %H:%M') stop.sh $STATUS"
  cos_python "$TPY" report "$TFILE" "closed: $(date '+%Y-%m-%d %H:%M') stop.sh $STATUS"
  echo "task: $NAME → status: $TST"
fi
grep -q "| $NAME |" "$COS_DIR/LEDGER.md" 2>/dev/null && cos_python - "$COS_DIR/LEDGER.md" "$NAME" "$STATUS" <<'PY'
import sys,re
p,n,st=sys.argv[1:]
lines=open(p).read().split("\n")
for i in range(len(lines)-1,-1,-1):
    if f"| {n} |" in lines[i]:
        cells=lines[i].split("|"); cells[7 if len(cells) > 8 else -2]=f" {st} "; lines[i]="|".join(cells); break   # status = 7th cell (legacy rows may have an 8th)
open(p,"w").write("\n".join(lines))
PY
[ -n "$TFILE" ] || echo "ledger: $NAME → $STATUS"
if [ -f "$MFILE" ]; then
  cos_python - "$MFILE" "$STATUS" "$(date '+%Y-%m-%d %H:%M')" <<'PY'
import re, sys
p, st, stamp = sys.argv[1:]
L = open(p, encoding="utf-8").read().split("\n")
cur = next((re.sub(r"\s+#.*", "", l.split(":", 1)[1]).strip().strip("\"'") for l in L if re.match(r"status:", l)), "active")
new = cur if cur in ("done", "parked", "stopped") else ("done" if st == "DONE" else "stopped")
L = [f"status: {new}            # active | done | parked | stopped" if re.match(r"status:", l) else l for l in L if not l.startswith("closed:")]
j = next((i for i, l in enumerate(L) if l.startswith("status:")), len(L) - 1)
L.insert(j + 1, f'closed: "{stamp} stop.sh {st}"')
open(p, "w", encoding="utf-8").write("\n".join(L))
print(f"mission: {p.rsplit('/', 1)[-1]} → status: {new}")
PY
fi
