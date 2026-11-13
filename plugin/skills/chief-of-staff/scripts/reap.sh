#!/usr/bin/env bash
# reap.sh — close the sessions finished workers leave open (session half; no browser handling here).
#   reap.sh [--dry-run] [--alert] [--only NAME] [--ended NAME] [--schedule NAME]
# A LIVE own worker (sessions.sh --tsv) whose latest report status line since its last STARTED is DONE →
#    `stop.sh NAME DONE`; latest PARKED (report line) or task `status: parked` → `stop.sh NAME PARKED`. Only once the
#    worker has been idle >= COS_REAP_IDLE_MIN (60) min OR its DONE/PARKED report line is that old (check-in pings
#    inside the window keep idle low). Inside that window the worker stays live for SendMessage follow-ups and
#    check-in pings. Every stop.sh gate stays; NEVER --force. A refusal leaves the session open, appends one `reap:`
#    report line to the task file and prints one line for the chief (--alert: only refusals not reported before;
#    state $COS_DIR/.reap-refused). A refusal in the detached Stop-hook run is queued in $COS_DIR/.reap-unseen and
#    printed by the next full run. The window opens at the last `status: STARTED` line only.
#    User-typed gate: a session where the user typed a turn (transcript origin.kind human) < COS_REAP_IDLE_MIN ago is
#    never reaped, whatever idle or its DONE line says — a DONE report is the worker's claim, not the user's.
#    Leads gate: a lead named in column 3 of $COS_DIR/LEADS (`<prefix> · <domain> · <lead> · <scope>`) is PERSISTENT —
#    never reaped; only a handover successor replaces it. Never the chief.
# --ended NAME   NAME's session is ending, so its own still-running pid does not count as live.
# --only NAME    one worker only.
# --schedule NAME  Stop-hook mode: if NAME is a stop candidate (DONE / parked), start ONE detached
#                `reap.sh --only NAME` after COS_REAP_DELAY_S (240) s (marker $COS_DIR/.reap-pending-NAME); returns at once.
# Wired: hooks/cos-reap.sh (Stop and SessionEnd; not a SessionEnd for /clear or resume); run it periodically (e.g. from next.sh or a cron) to catch panes killed without a Stop.
# Off switch: COS_REAP=0. Every action is logged to $COS_DIR/reap.log. Test overrides: COS_REAP_SESSIONS_TSV, COS_REAP_STOP.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/cos-env.sh"
[ "${COS_REAP:-1}" != 0 ] || exit 0
DRY=0 ALERT=0 ONLY= ENDED= SCHED= HOOKRUN=0
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY=1; shift;; --alert) ALERT=1; shift;; --only) ONLY="$2"; shift 2;; --ended) ENDED="$2"; shift 2;;
  --sessions-only) shift;; --schedule) SCHED="$2"; shift 2;;
  --from-hook) HOOKRUN=1; shift;;   # internal: the detached --schedule run (stdout is /dev/null)
  *) echo "unknown arg: $1" >&2; exit 2;; esac; done
TPY="$HERE/lib/tasks.py"
LOG="$COS_DIR/reap.log"
log() { [ "$DRY" = 1 ] || printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }
say() { [ "$ALERT" = 1 ] || printf '%s\n' "$*"; log "$*"; }

# plan → TSV rows: stop|wait NAME STATUS IDLE AGE
plan() {
  local sess; sess=$(if [ -n "${COS_REAP_SESSIONS_TSV:-}" ]; then cat "$COS_REAP_SESSIONS_TSV"; else "$HERE/sessions.sh" --tsv; fi 2>/dev/null)   # override: tests only || { echo "reap: sessions.sh failed — nothing done (liveness unknown)" >&2; return 1; }
  [ -n "$sess" ] || { echo "reap: sessions.sh empty — nothing done (liveness unknown)" >&2; return 1; }
  COS_SESS="$sess" cos_python - "$COS_DIR" "$HERE/lib" \
    "$ONLY" "$ENDED" "${COS_REAP_IDLE_MIN:-60}" "$COS_PREFIX" "$COS_HOST_PREFIX" <<'PY'
import json, os, re, sys, time
cosdir, lib, only, ended, idle_min, pfx, host = sys.argv[1:]
sys.path.insert(0, lib); import tasks as T
live, idle = {}, {}
for l in os.environ.get("COS_SESS", "").splitlines()[1:]:   # stdin is this script (heredoc)
    c = l.split("\t")
    if len(c) >= 5 and c[0] == "live":
        live[c[1]] = live.get(c[1], 0) + 1
        try: i = int(c[4])
        except ValueError: i = -1
        idle[c[1]] = i if c[1] not in idle else min(idle[c[1]], i)
if ended and live.get(ended, 0) <= 1: live.pop(ended, None)   # its own ending pid is not "live"
def own(w):   # mirror of cos-env.sh cos_own
    m = re.match(r"([a-z])-", w or "")
    if not m: return pfx == host
    return m.group(1) == pfx
CLOSED = {"done", "stopped", "failed"}
STAT = re.compile(r"status:\s*\**\s*(STARTED|RESUMED|WORKING|BLOCKED|DONE|FAILED|PARKED|STOPPED)\b")
STARTED = re.compile(r"status:\s*\**\s*STARTED\b")
STAMP = re.compile(r"status:\s*\**\s*\S+\s+(\d{4}-\d\d-\d\d \d\d:\d\d)")   # a `status: STARTED` line, never a `reap:` line quoting stop.sh
now = time.time()
rows = T.list_tasks(cosdir)
def leads(d):   # column 3 of $COS_DIR/LEADS (`<prefix> · <domain> · <lead> · <scope>`)
    try: L = open(os.path.join(d, "LEADS"), encoding="utf-8", errors="ignore").read().split("\n")
    except OSError: return set()
    return {c[2].split()[0] for c in (l.split("·") for l in L if l.strip() and not l.lstrip().startswith("#")) if len(c) >= 3 and c[2].split()}
LEADS = leads(cosdir)
import lastturn as LT
human = {} if os.environ.get("COS_REAP_SESSIONS_TSV") else LT.live_human_turns()   # tests: no live registry
for p, fm in rows:
    n = str(fm.get("name") or "")
    if not n or (only and n != only) or n not in live or not own(n): continue
    if n == "chief" or re.search(r"(^|-)chief(-|$)", n): continue          # never the chief
    if n in LEADS: continue                                                # never a LEADS lead (persistent)
    st = str(fm.get("status") or "").lower()
    if st in CLOSED: continue
    try: _, body = T.read(p)
    except Exception: continue
    lines = T.reports(body).split("\n")
    start = max([i for i, l in enumerate(lines) if STARTED.search(l)] or [0])
    last = since = None   # since: stamp of the first line of the trailing DONE/PARKED run
    for l in lines[start:]:
        m = STAT.search(l)
        if not m: continue
        if m.group(1) not in ("DONE", "PARKED"): since = None
        elif last not in ("DONE", "PARKED"):
            d = STAMP.search(l)
            since = time.mktime(time.strptime(d.group(1), "%Y-%m-%d %H:%M")) if d else None
        last = m.group(1)
    want = "DONE" if last == "DONE" else ("PARKED" if last == "PARKED" or st == "parked" else None)
    i = idle.get(n, -1)
    if not want: continue
    age = int((now - since) / 60) if since and want in ("DONE", "PARKED") else -1
    # the window after the DONE/PARKED report closes it even if check-in pings kept idle low
    go = i >= int(idle_min) or age >= int(idle_min)
    # never reap a session the user TYPED in within the window
    h = human.get(n, -1)
    if go and h >= 0 and (now - h) < int(idle_min) * 60: go = False
    print("\t".join(["stop" if go else "wait", n, want, str(i), str(age)]))
PY
}

if [ -n "$SCHED" ]; then   # Stop-hook mode: cheap check, then one detached delayed run
  [ -n "$(ONLY=$SCHED; plan 2>/dev/null | awk -F'\t' -v n="$SCHED" '$2==n')" ] || exit 0
  MK="$COS_DIR/.reap-pending-$SCHED"
  [ -z "$(find "$MK" -maxdepth 0 -mmin -15 2>/dev/null)" ] || exit 0   # one already scheduled
  [ "$DRY" = 0 ] || { echo "DRY-RUN: would schedule reap.sh --only $SCHED in ${COS_REAP_DELAY_S:-240}s"; exit 0; }
  touch "$MK"; log "scheduled: reap.sh --only $SCHED in ${COS_REAP_DELAY_S:-240}s (task reports DONE/parked)"
  env -u COS_WORKER bash -c '. "$1"; shift; cos_python - "$@"' _ "$HERE/lib/cos-os.sh" "${COS_REAP_DELAY_S:-240}" "$HERE/reap.sh" "$SCHED" "$MK" <<'PY'
import os, sys, time
delay, script, name, mk = sys.argv[1:]
if os.fork(): sys.exit(0)
os.setsid()
if os.fork(): os._exit(0)
fd = os.open(os.devnull, os.O_RDWR)
for i in (0, 1, 2): os.dup2(fd, i)
time.sleep(int(delay))
try: os.unlink(mk)
except OSError: pass
os.execvp("bash", ["bash", script, "--only", name, "--from-hook"])
PY
  exit 0
fi

STATE="$COS_DIR/.reap-refused"; NEWSTATE=
# A refusal in the detached Stop-hook run (--from-hook, stdout = /dev/null) is queued in UNSEEN; the next full run
# (--alert or not) prints it once — so every refusal reaches the chief as one line.
UNSEEN="$COS_DIR/.reap-unseen"; FLUSHED=
if [ -z "$ONLY" ] && [ -s "$UNSEEN" ]; then
  FLUSHED=$(cat "$UNSEEN"); printf '%s\n' "$FLUSHED"
  [ "$DRY" = 1 ] || { while IFS= read -r l; do log "$l (printed)"; done < "$UNSEEN"; rm -f "$UNSEEN"; }
fi
if true; then
  while IFS=$'\t' read -r act n st idl age; do
    [ -n "$act" ] || continue
    if [ "$act" = wait ]; then [ "$ALERT" = 1 ] || echo "reap: $n reports $st, idle ${idl}m, report ${age}m old < ${COS_REAP_IDLE_MIN:-60}m — next run"; continue; fi
    cos_own "$n" || continue
    if [ "$DRY" = 1 ]; then echo "DRY-RUN: would run stop.sh $n $st (idle ${idl}m, report ${age}m old)"; continue; fi
    rc=0; out=$("${COS_REAP_STOP:-$HERE/stop.sh}" "$n" "$st" 2>&1) || rc=$?   # COS_REAP_STOP: tests only
    if [ "$rc" = 0 ]; then say "reap: closed $n — stop.sh $n $st"; continue; fi
    why=$(printf '%s\n' "$out" | awk '/^WARN:/ {sub(/^WARN: /, ""); w=$0} END {print w}')
    line="reap: $n left open — stop.sh $n $st refused (exit $rc)${why:+: $why}"
    key="$n	$st	$rc	$why"; NEWSTATE="$NEWSTATE$key"$'\n'
    if [ -f "$STATE" ] && grep -qxF "$key" "$STATE"; then [ "$ALERT" = 1 ] || grep -qxF "$line" <<<"$FLUSHED" || echo "$line"; continue; fi
    printf '%s\n' "$line"; log "$line"
    if [ "$HOOKRUN" = 1 ]; then printf '%s\n' "$line" >> "$UNSEEN"; printf '%s\n' "$key" >> "$STATE"; fi
    cos_python "$TPY" report "$COS_DIR/tasks/$n.md" "reap: $(date '+%Y-%m-%d %H:%M') stop.sh $st refused (exit $rc)${why:+: $why} — left open; fix it and the next reap closes it" >/dev/null 2>&1 || true
  done < <(plan)
  [ "$DRY" = 1 ] || [ -n "$ONLY" ] || printf '%s' "$NEWSTATE" > "$STATE" 2>/dev/null || true
fi
exit 0
