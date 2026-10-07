#!/usr/bin/env bash
# Check in with this machine's live workers — cheaply. Run by a check-in schedule (e.g. every 30 min) and by every SWEEP.
#   checkin.sh [--dry-run] [--silent-min 30] [--max-idle-min 60]
# Pings (types `⟦CK⟧` + Enter into the worker's tmux window or cmux pane) ONLY a worker that:
#   - is this machine's (cos-env.sh cos_own) and its LEDGER/task row is STARTED|WORKING|BLOCKED with a local pane,
#   - has a live pid (sessions.sh), and
#   - has been silent > --silent-min: no heartbeat (hooks/cos-heartbeat.sh touches $COS_DIR/.heartbeat/<worker>
#     on every tool call / turn end) and no report-file write for that long.
# Never pings a session idle > --max-idle-min (never re-message a session idle > 1 h — its cache is cold;
# it is listed as `skip idle` for the chief to judge). Remote (tmux) workers are listed, never pinged.
# The cos-ck hook turns the 5-character ping into the 3-line protocol (protocols/ck.md). Print launcher:
# workers have no pane the chief can type into — they are listed, never pinged.
# Prints one line per worker + a summary; writes nothing to the state dir.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"
DRY=0 SILENT=30 MAXIDLE=60
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY=1; shift;; --silent-min) SILENT="$2"; shift 2;; --max-idle-min) MAXIDLE="$2"; shift 2;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; done
SESS=$("$HERE/sessions.sh" --tsv 2>/dev/null || true)
export COS_REMOTE_MACHINE_PREFIX="${COS_REMOTE_MACHINE_PREFIX:-}"
PLAN=$(cos_python - "$COS_DIR" "$SESS" "$SILENT" "$MAXIDLE" <<'PY'
import os, re, sys, time, glob
cosdir, sess, silent, maxidle = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
PFX, HOST, RPFX = os.environ["COS_PREFIX"], os.environ["COS_HOST_PREFIX"], os.environ.get("COS_REMOTE_MACHINE_PREFIX", "")
def own(w):
    m = re.match(r"([a-z])-", w or "")
    if not m: return PFX == HOST
    return m.group(1) == PFX or (PFX == HOST and bool(RPFX) and m.group(1) == RPFX)
now = time.time()
live = {}
for l in sess.splitlines()[1:]:
    p = l.split("\t")   # sessions.sh --tsv: full name (the padded table cut it at 22 chars)
    if len(p) >= 5 and p[0] == "live": live[p[1]] = int(p[4]) if p[4].lstrip("-").isdigit() else -1
rows = {}   # worker -> (where, status, report file)
lp = os.path.join(cosdir, "LEDGER.md")
if os.path.exists(lp):
    for l in open(lp, encoding="utf-8", errors="ignore"):
        c = [x.strip() for x in l.strip().strip("|").split("|")]
        if len(c) >= 7 and re.match(r"\d{4}-\d\d-\d\d", c[0]):
            rows[c[1]] = (c[2], c[6], os.path.join(cosdir, "inbox", c[1] + ".md"))
for f in glob.glob(os.path.join(cosdir, "tasks", "*.md")):   # task files override LEDGER rows
    fm = {}
    lines = open(f, encoding="utf-8", errors="ignore").read().split("\n")
    if lines and lines[0] == "---":
        for l in lines[1:]:
            if l == "---": break
            m = re.match(r"([\w-]+):\s*(.*)", l)
            if m: fm[m.group(1)] = m.group(2).strip().strip("\"'")
    if fm.get("name"): rows[fm["name"]] = (fm.get("where", ""), fm.get("status", ""), f)
for w, (where, st, rep) in sorted(rows.items()):
    if not own(w) or not re.match(r"(STARTED|WORKING|BLOCKED|running|claimed)\b", st, re.I): continue
    if w not in live: continue
    marks = [os.path.getmtime(x) for x in (os.path.join(cosdir, ".heartbeat", w), rep) if os.path.exists(x)]
    quiet = int((now - max(marks)) / 60) if marks else 10**6
    idle = live[w]
    m = re.search(r"ws(\d+)/(surface:\d+)", where)
    tm = re.match(r"tmux (\S+)", where)
    if quiet <= silent: act = "ok"
    elif idle > maxidle: act = "skip-idle"
    elif not m and not tm: act = "skip-remote" if where.startswith("remote") else "skip-nopane"
    else: act = "ping"
    print("\t".join([act, w, str(quiet), str(idle), f"workspace:{m.group(1)}" if m else ("tmux" if tm else "-"), m.group(2) if m else (tm.group(1) if tm else "-")]))
PY
)
CM="${COS_CMUX_BIN:-cmux}"   # COS_CMUX_BIN: tests point it at a fake
ping() {  # ping WS SURF — tmux window target, or cmux workspace/surface
  if [ "$1" = tmux ]; then command -v tmux >/dev/null 2>&1 && cos_tmux send-keys -t "$2" '⟦CK⟧' Enter
  else command -v "$CM" >/dev/null 2>&1 && "$CM" send --workspace "$1" --surface "$2" '⟦CK⟧\r' >/dev/null 2>&1; fi
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
    skip-idle) echo "skip  $w — idle ${idle}m > ${MAXIDLE}m: never re-message; chief decides (stop + --continues successor)";;
    *) echo "skip  $w — $act (silent ${quiet}m)";;
  esac
done <<< "$PLAN"
echo "checkin: $n live worker(s) on ${COS_PREFIX}, $p pinged$([ "$DRY" = 1 ] && echo ' (dry-run)')"
