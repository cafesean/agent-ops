#!/usr/bin/env bash
# Latest report of every worker: task files (tasks/<name>.md) first, then legacy inboxes (inbox/<name>.md)
# of workers that have no task file. Remote workers' reports (~/cos/inbox/<name>.md on the remote runner add-on) are pulled
# and their new lines appended under `## Reports` of the matching task file (legacy: copied into inbox/).
#   collect.sh          summary: worker · status · age_m · last line
#   collect.sh NAME     the full task file (or legacy inbox) of one worker
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"
if [ $# -gt 0 ]; then cat "$COS_DIR/tasks/$1.md" 2>/dev/null || cat "$COS_DIR/inbox/$1.md" 2>/dev/null; exit 0; fi

# Pull remote reports (best effort)
if [ -n "${COS_REMOTE_USER:-}" ] && RHOST=$(cos_remote_host) && [ -n "$RHOST" ]; then
  RT=$(mktemp -d)
  if scp -q -o BatchMode=yes -o ConnectTimeout=5 "$COS_REMOTE_USER@$RHOST:cos/inbox/*.md" "$RT/" 2>/dev/null; then
    cos_python - "$RT" "$COS_DIR" "$HERE/lib" <<'PY'
import os, sys
rt, cos, lib = sys.argv[1:]
sys.path.insert(0, lib); import tasks as T
for f in os.listdir(rt):
    tp = os.path.join(cos, "tasks", f)
    src = open(os.path.join(rt, f), encoding="utf-8", errors="ignore").read().split("\n")
    if os.path.exists(tp):
        have = set(T.reports(open(tp, encoding="utf-8", errors="ignore").read()).split("\n"))
        new = [l for l in src if l.strip() and not l.startswith("# ") and l not in have]
        if new: T.append_report(tp, new)
    else:
        os.makedirs(os.path.join(cos, "inbox"), exist_ok=True)
        open(os.path.join(cos, "inbox", f), "w", encoding="utf-8").write("\n".join(src))
PY
  fi
  rm -rf "$RT"
fi
cos_python - "$COS_DIR" "$HERE/lib" <<'PY'
import os, re, sys, time, glob
cos, lib = sys.argv[1:]
sys.path.insert(0, lib); import tasks as T
now = time.time()
print(f"{'worker':24} {'status':10} {'age_m':>6}  last")
seen = set()
def row(name, st, path, text):
    lines = [l for l in text.split("\n") if l.strip() and not l.startswith("#") and not l.startswith("---")]
    last = lines[-1][:90] if lines else ""
    print(f"{name:24} {st:10} {int((now - os.path.getmtime(path)) / 60):>6}  {last}")
for p, fm in T.list_tasks(cos):
    seen.add(fm.get("name"))
    body = open(p, encoding="utf-8", errors="ignore").read()
    rep = T.reports(T.split(body)[1])
    m = [l for l in rep.split("\n") if l.startswith("status:")]
    st = str(fm.get("status") or "?")
    if st in ("claimed", "running") and m: st = m[-1].split()[1]   # the worker's own latest status word
    row(fm.get("name"), {"done": "DONE", "failed": "FAILED", "stopped": "STOPPED", "parked": "PARKED", "open": "QUEUED"}.get(st, st), p, rep)
for f in sorted(glob.glob(os.path.join(cos, "inbox", "*.md"))):
    n = os.path.basename(f)[:-3]
    if n in seen: continue
    t = open(f, encoding="utf-8", errors="ignore").read()
    st = [l for l in t.split("\n") if l.startswith("status:")]
    row(n, (st[-1].split()[1] if st and len(st[-1].split()) > 1 else "?"), f, "\n".join(l for l in t.split("\n") if not l.startswith("status:")))
PY
