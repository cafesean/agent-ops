#!/usr/bin/env bash
# List live Claude sessions on this machine: pid, name, age, idle minutes, last turn, cwd.
# Idle = minutes since the transcript's last user/assistant entry (lib/lastturn.py), NOT the file mtime, which
# non-turn writes bump. The table marks an mtime fallback with '?' (e.g. 12?); --tsv stays numeric.
#   sessions.sh --tsv      machine-read: same columns, TAB-separated, full name, no padding. EVERY script that
#                          matches a worker by name must use this — the padded table is for eyes only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/cos-os.sh"   # COS_PYTHON / cos_python (works without a config too)
TSV=0; [ "${1:-}" != --tsv ] || TSV=1
cos_python - "$TSV" "$HERE/lib" <<'PY'
import json, os, glob, time, re, sys
sys.path.insert(0, sys.argv[2]); from lastturn import last_turn, label
now = time.time()
def pid_alive(pid):
    # NEVER os.kill(pid, 0) on Windows: there it calls TerminateProcess and kills the session.
    if not isinstance(pid, int) or pid <= 0: return False
    if os.name == "nt":
        try:
            import ctypes
            k = ctypes.windll.kernel32
            h = k.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
            if not h: return False
            code = ctypes.c_ulong(); ok = k.GetExitCodeProcess(h, ctypes.byref(code)); k.CloseHandle(h)
            return bool(ok) and code.value == 259    # STILL_ACTIVE
        except Exception: return False
    try: os.kill(pid, 0); return True
    except PermissionError: return True
    except Exception: return False
rows = []
for f in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try: d = json.load(open(f))
    except Exception: continue
    pid = d.get("pid")
    alive = pid_alive(pid)
    cwd = d.get("cwd") or ""
    proj = re.sub(r"[^A-Za-z0-9]", "-", cwd) if os.name == "nt" else cwd.replace("/", "-").replace(".", "-")
    tr = os.path.expanduser(f"~/.claude/projects/{proj}/{d.get('sessionId')}.jsonl")
    lt, exact = last_turn(tr)
    idle = max(0, int((now - lt) / 60)) if lt >= 0 else -1
    age = int((now - (d.get("startedAt") or now*1000)/1000) / 60)
    rows.append((alive, d.get("name") or "-", pid, age, idle, exact or idle < 0, cwd, lt))
rows.sort(key=lambda r: (not r[0], r[4] if r[4] >= 0 else 10**9))
tsv = sys.argv[1] == "1"
w = max([22] + [len(r[1]) for r in rows])   # widen to the longest name — never cut it
if tsv: print("\t".join(["state", "name", "pid", "age_m", "idle_m", "cwd"]))
else: print(f"{'state':6} {'name':{w}} {'pid':>7} {'age_m':>6} {'idle_m':>6} {'last turn':20}  cwd")
for alive, name, pid, age, idle, exact, cwd, lt in rows:
    state = "live" if alive else "DEAD"
    if tsv: print("\t".join([state, re.sub(r"[\t\r\n]+", " ", name), str(pid), str(age), str(idle), cwd]))
    else: print(f"{state:6} {name:{w}} {pid:>7} {age:>6} {str(idle) + ('' if exact else '?'):>6} {label(lt, now):20}  {cwd}")
PY
