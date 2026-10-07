#!/usr/bin/env bash
# Close old state so the state dir stays small. Never deletes: everything moves to
# $COS_DIR/_archive/<kind>/ and is made read-only (chmod a-w). Run by the sweep once a day (safe to run any time).
#   archive.sh [--dry-run] [--all-prefixes]
#     - tasks/<n>.md with status done|failed|stopped, closed > 24 h ago   → _archive/tasks/
#     - briefs/: all but the newest 3 timestamped briefs                  → _archive/briefs/
#   Only this machine's workers (name prefix COS_MACHINE_PREFIX; the host machine also owns the remote
#   runner's prefix) unless --all-prefixes.
#   Never touches GOALS.md, STATE.md, Outstanding.md or any add-on file.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"
DRY=0 ALLP=0
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY=1; shift;; --all-prefixes) ALLP=1; shift;;
  -h|--help) sed -n '2,9p' "$0"; exit 0;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; done
export COS_REMOTE_MACHINE_PREFIX="${COS_REMOTE_MACHINE_PREFIX:-}"
cos_python - "$COS_DIR" "$DRY" "$ALLP" "$HERE/lib" <<'PY'
import os, re, sys, glob, shutil, stat, time
cos, dry, allp, lib = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1", sys.argv[4]
sys.path.insert(0, lib); import tasks as T
PFX, HOST, RPFX = os.environ["COS_PREFIX"], os.environ["COS_HOST_PREFIX"], os.environ.get("COS_REMOTE_MACHINE_PREFIX", "")
def own(w):
    if allp: return True
    m = re.match(r"([a-z])-", w or "")
    if not m: return PFX == HOST
    return m.group(1) == PFX or (PFX == HOST and bool(RPFX) and m.group(1) == RPFX)
now = time.time()
A = os.path.join(cos, "_archive")
moves = []
def ro(p):
    for root, ds, fs in (os.walk(p) if os.path.isdir(p) else [(os.path.dirname(p), [], [os.path.basename(p)])]):
        for f in fs:
            q = os.path.join(root, f); os.chmod(q, os.stat(q).st_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
def move(src, dst):
    if not os.path.exists(src): return
    if os.path.exists(dst):
        b, e = os.path.splitext(dst); n = 2
        while os.path.exists(f"{b}-{n}{e}"): n += 1
        dst = f"{b}-{n}{e}"
    moves.append(f"{os.path.relpath(src, cos)} → {os.path.relpath(dst, cos)}")
    if dry: return
    os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.move(src, dst); ro(dst)
# ---- tasks ----
for p, fm in T.list_tasks(cos):
    if not own(fm.get("name")) or str(fm.get("status")) not in ("done", "failed", "stopped"): continue
    c = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d)", str(fm.get("closed") or ""))
    t = time.mktime(time.strptime(c.group(1), "%Y-%m-%d %H:%M")) if c else os.path.getmtime(p)
    if now - t > 86400: move(p, os.path.join(A, "tasks", os.path.basename(p)))
# ---- briefs: keep the newest 3 timestamped ----
bs = sorted(glob.glob(os.path.join(cos, "briefs", "*.md")))
stamped = [b for b in bs if re.search(r"\d{4}-\d\d-\d\d-\d{4}\.md$", b)]
for b in [b for b in bs if b not in stamped[-3:]]:
    move(b, os.path.join(A, "briefs", os.path.basename(b)))
print("\n".join(("DRY-RUN " if dry else "") + m for m in moves) if moves else "archive: nothing to move")
print(f"archive: {len(moves)} move(s){' (dry-run)' if dry else ''} · prefixes: {'all' if allp else PFX}")
PY
