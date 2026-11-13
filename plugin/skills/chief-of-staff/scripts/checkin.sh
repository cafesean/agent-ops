#!/usr/bin/env bash
# Check in with this machine's live workers — cheaply. Run by a check-in schedule (e.g. every 30 min) and by every SWEEP.
#   checkin.sh [--dry-run] [--silent-min N] [--max-idle-min N] [--only "w1 w2"]
#   Defaults: --silent-min $COS_CHECKIN_SILENT_MIN (20), --max-idle-min $COS_CHECKIN_MAX_IDLE_MIN (50).
#   --only: ping just these workers, silent or not (an answer to one of their asks just landed — act now). Live pid,
#   own pane, idle <= --max-idle-min and no_ping still apply; the silence gate does not, so a worker mid-turn gets
#   ⟦CK⟧ too — the prompt queues behind its turn.
# Pings (types `⟦CK⟧` + Enter into the worker's tmux window or cmux pane) ONLY a worker that:
#   - is this machine's (cos-env.sh cos_own) and its LEDGER/task row is STARTED|WORKING|BLOCKED|DONE with a local pane,
#   - has a live pid (sessions.sh), and
#   - has been silent > --silent-min: no heartbeat (hooks/cos-heartbeat.sh touches $COS_DIR/.heartbeat/<worker>
#     on every tool call / turn end) and no real turn for that long (quiet = newer of heartbeat and last turn; NOT
#     the task-file mtime — sweeps stamp task files, so idle workers would look "heard").
# Never pings a session idle > --max-idle-min (idle = last user/assistant turn, lib/lastturn.py via sessions.sh, not
# mtime; never re-message a session whose prompt cache is cold — it is listed as `skip idle` for the chief to judge).
# Default 50, not 60: a ping at idle 59-60 lands past the 1 h prompt cache and re-reads the whole context cold.
# BLOCKED workers ARE pinged: a worker waiting on the owner keeps its cache warm, so the answer lands on a warm session.
# DONE/PARKED workers are pinged until 60 min after their DONE/PARKED report (`skip done-1h`); reap.sh closes them.
# A worker whose successor task (`continues: <worker>`) is running is never pinged (`skip superseded`).
# A task with `no_ping: true` is never pinged (a session that has its own wait loop as heartbeat).
# The cos-ck hook turns the 5-character ping into the 3-line protocol (protocols/ck.md). Print launcher:
# workers have no pane the chief can type into — they are listed, never pinged.
# Prints one line per worker + a summary; writes nothing to the state dir.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"
DRY=0 SILENT=${COS_CHECKIN_SILENT_MIN:-20} MAXIDLE=${COS_CHECKIN_MAX_IDLE_MIN:-50} ONLY=""
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY=1; shift;; --silent-min) SILENT="$2"; shift 2;; --max-idle-min) MAXIDLE="$2"; shift 2;;
  --only) ONLY="$2"; SILENT=-1; shift 2;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; done
SESS=$("$HERE/sessions.sh" --tsv 2>/dev/null || true)
PLAN=$(cos_python - "$COS_DIR" "$SESS" "$SILENT" "$MAXIDLE" "$ONLY" <<'PY'
import os, re, sys, time, glob
cosdir, sess, silent, maxidle = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
only = set(sys.argv[5].split())
PFX, HOST = os.environ["COS_PREFIX"], os.environ["COS_HOST_PREFIX"]
def own(w):
    m = re.match(r"([a-z])-", w or "")
    if not m: return PFX == HOST
    return m.group(1) == PFX
now = time.time()
live = {}
for l in sess.splitlines()[1:]:
    p = l.split("\t")   # sessions.sh --tsv: full name (the padded table cut it at 22 chars)
    if len(p) >= 5 and p[0] == "live": live[p[1]] = int(p[4]) if p[4].lstrip("-").isdigit() else -1
rows = {}   # worker -> (where, status, report file)
superseded = set()   # workers whose running successor (task `continues:`) owns the line
lp = os.path.join(cosdir, "LEDGER.md")
if os.path.exists(lp):
    for l in open(lp, encoding="utf-8", errors="ignore"):
        c = [x.strip() for x in l.strip().strip("|").split("|")]
        if len(c) >= 7 and re.match(r"\d{4}-\d\d-\d\d", c[0]):
            rows[c[1]] = (c[2], c[6], os.path.join(cosdir, "inbox", c[1] + ".md"), False, None)
for f in glob.glob(os.path.join(cosdir, "tasks", "*.md")):   # task files override LEDGER rows
    fm = {}
    lines = open(f, encoding="utf-8", errors="ignore").read().split("\n")
    if lines and lines[0] == "---":
        for l in lines[1:]:
            if l == "---": break
            m = re.match(r"([\w-]+):\s*(.*)", l)
            if m: fm[m.group(1)] = m.group(2).strip().strip("\"'")
    if fm.get("continues") and re.match(r"(STARTED|WORKING|BLOCKED|running|claimed)\b", fm.get("status", ""), re.I): superseded.add(fm["continues"])
    last = [l for l in lines if l.startswith("status: ")]
    done_since = None   # stamp of the first line of the trailing DONE*/PARKED run
    for l in reversed(last):
        if not l.startswith(("status: DONE", "status: PARKED")): break
        ds = re.match(r"status: \S+ (\d{4}-\d\d-\d\d \d\d:\d\d)", l)
        if ds: done_since = time.mktime(time.strptime(ds.group(1), "%Y-%m-%d %H:%M"))
    if last and last[-1].startswith("status: PARKED"): done_since = -1   # sentinel: parked, never pinged
    name = os.path.basename(f)[:-3]   # identity = file name
    rows[name] = (fm.get("where", ""), fm.get("status", ""), f, fm.get("no_ping", "").lower() == "true", done_since)
for w, (where, st, rep, noping, done_since) in sorted(rows.items()):
    if not own(w) or not re.match(r"(STARTED|WORKING|BLOCKED|DONE|running|claimed|done)\b", st, re.I): continue
    if only and w not in only: continue
    if w not in live: continue
    idle = live[w]
    hb = os.path.join(cosdir, ".heartbeat", w)
    quiet = min(int((now - os.path.getmtime(hb)) / 60) if os.path.exists(hb) else 10**6, idle if idle >= 0 else 10**6)
    m = re.search(r"ws(\d+)/(surface:\d+)", where)
    tm = re.match(r"tmux (\S+)", where)
    if noping: act = "skip-noping"
    elif w in superseded: act = "skip-superseded"
    elif quiet <= silent: act = "ok"
    elif done_since == -1: act = "skip-parked"
    elif done_since is not None and now - done_since >= 3600: act = "skip-done-1h"
    elif idle > maxidle: act = "skip-idle"
    elif not m and not tm: act = "skip-nopane"
    else: act = "ping"
    print("\t".join([act, w, str(quiet), str(idle), f"workspace:{m.group(1)}" if m else ("tmux" if tm else "-"), m.group(2) if m else (tm.group(1) if tm else "-")]))
PY
)
CM="${COS_CMUX_BIN:-cmux}"   # COS_CMUX_BIN: tests point it at a fake
ping() {  # ping WS SURF — tmux window target, or cmux workspace/surface
  if [ "$1" = tmux ]; then cos_has_tmux && cos_tmux send-keys -t "$2" '⟦CK⟧' Enter
  else command -v "$CM" >/dev/null 2>&1 && { "$CM" send --workspace "$1" --surface "$2" '⟦CK⟧\r' >/dev/null 2>&1 || "$CM" send --surface "$2" '⟦CK⟧\r' >/dev/null 2>&1; }; fi
}
n=0 p=0
while IFS=$'\t' read -r act w quiet idle ws surf; do
  [ -n "$act" ] || continue; n=$((n+1))
  case "$act" in
    ping)
      if [ "$DRY" = 1 ]; then echo "DRY-RUN ping $w (silent ${quiet}m, idle ${idle}m) → $ws $surf ⟦CK⟧"
      elif ping "$ws" "$surf"; then echo "pinged $w (silent ${quiet}m, idle ${idle}m)"; p=$((p+1))
      else echo "WARN: ping $w failed ($ws/$surf gone?)" >&2; fi;;
    ok) echo "ok    $w (heard ${quiet}m ago)";;
    skip-noping) echo "skip  $w — no_ping: true";;
    skip-done-1h) echo "skip  $w — DONE/PARKED >= 60 min ago: no ping, reap.sh closes it";;
    skip-superseded) echo "skip  $w — a running successor owns this line: no ping, no wake";;
    skip-parked) echo "skip  $w — PARKED: no ping; the worker stays parked until its owner resumes it";;
    skip-idle) echo "skip  $w — idle ${idle}m > ${MAXIDLE}m: never re-message; chief decides (stop + --continues successor)";;
    *) echo "skip  $w — $act (silent ${quiet}m)";;
  esac
done <<< "$PLAN"
echo "checkin: $n live worker(s) on ${COS_PREFIX}, $p pinged$([ "$DRY" = 1 ] && echo ' (dry-run)')"
