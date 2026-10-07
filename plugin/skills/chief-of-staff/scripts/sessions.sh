#!/usr/bin/env bash
# List live Claude sessions on this machine: pid, name, age, idle minutes, account, cwd.
# Idle = minutes since the session transcript was last written. Account = the LEDGER `account` column of the
# worker's last row (a, b…); `-` = not a chief-spawned worker or a row with no account (both run on a).
#   sessions.sh --remote   the remote runner add-on instead (one ssh): live claude count, tmux windows, last inbox status line.
#   sessions.sh --tsv      machine-read: same columns, TAB-separated, full name, no padding. EVERY script that
#                          matches a worker by name must use this — the padded table is for eyes only.
set -euo pipefail
if [ "${1:-}" = --remote ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/cos-env.sh"
  RHOST=$(cos_remote_host) && [ -n "${COS_REMOTE_USER:-}" ] || { echo "addon remote-runner not configured, skipping"; exit 0; }
  RTX="$(printf '%q' "${COS_REMOTE_TMUX_BIN:-tmux}")${COS_REMOTE_TMUX_SOCKET:+ -S $(printf '%q' "$COS_REMOTE_TMUX_SOCKET")}"
  exec ssh -o BatchMode=yes -o ConnectTimeout=8 "$COS_REMOTE_USER@$RHOST" "bash -s" <<R
echo "remote ${COS_REMOTE_HOST_KEY:-$RHOST}: \$(pgrep -u "\$USER" -x claude | wc -l | tr -d ' ')/${COS_REMOTE_MAX_SESSIONS:-3} live claude"
printf '%-24s %-8s %s\n' window cmd cwd
$RTX list-windows -t ${COS_REMOTE_TMUX_SESSION:-agent-ops} -F '#{window_name} #{pane_current_command} #{pane_current_path}' 2>/dev/null | while read -r n c d; do printf '%-24s %-8s %s\n' "\$n" "\$c" "\$d"; done
for f in ~/cos/inbox/*.md; do [ -e "\$f" ] || continue; printf '%-24s %s\n' "\$(basename "\$f" .md)" "\$(grep -E '^status:' "\$f" | tail -1)"; done
R
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/cos-os.sh"   # COS_PYTHON / cos_python (works without a config too)
LEDGER=$( ( . "$HERE/cos-env.sh" >/dev/null 2>&1 && printf '%s' "$COS_DIR/LEDGER.md" ) || true)   # its dir's tasks/ too
TSV=0; [ "${1:-}" != --tsv ] || TSV=1
cos_python - "$LEDGER" "$TSV" <<'PY'
import json, os, glob, time, re, sys
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
acct = {}
if sys.argv[1] and os.path.exists(sys.argv[1]):
    for l in open(sys.argv[1], encoding="utf-8", errors="ignore"):
        c = [x.strip() for x in l.strip().strip("|").split("|")]
        if len(c) >= 7 and re.match(r"\d{4}-\d\d-\d\d", c[0]):
            acct[c[1]] = c[7] if len(c) >= 8 and re.fullmatch(r"[a-z][a-z0-9]{0,5}", c[7]) else "-"

    for _d in [os.path.join(os.path.dirname(sys.argv[1]), "tasks")]:   # task files carry the account
        for _f in (sorted(os.listdir(_d)) if os.path.isdir(_d) else []):
            if not _f.endswith(".md") or _f.startswith("."): continue
            _fm = {}
            _L = open(os.path.join(_d, _f), encoding="utf-8", errors="ignore").read().split("\n")
            if _L and _L[0] == "---":
                for _l in _L[1:]:
                    if _l == "---": break
                    _m = re.match(r"(name|account):\s*(.*)", _l)
                    if _m: _fm[_m.group(1)] = _m.group(2).strip().strip("\"'")
            if _fm.get("account"): acct[_fm.get("name") or _f[:-3]] = _fm["account"]
rows = []
for f in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try: d = json.load(open(f))
    except Exception: continue
    pid = d.get("pid")
    alive = pid_alive(pid)
    cwd = d.get("cwd") or ""
    proj = re.sub(r"[^A-Za-z0-9]", "-", cwd) if os.name == "nt" else cwd.replace("/", "-").replace(".", "-")
    tr = os.path.expanduser(f"~/.claude/projects/{proj}/{d.get('sessionId')}.jsonl")
    idle = int((now - os.path.getmtime(tr)) / 60) if os.path.exists(tr) else -1
    age = int((now - (d.get("startedAt") or now*1000)/1000) / 60)
    rows.append((alive, d.get("name") or "-", pid, age, idle, d.get("kind"), cwd))
rows.sort(key=lambda r: (not r[0], r[4] if r[4] >= 0 else 10**9))
tsv = sys.argv[2] == "1"
w = max([22] + [len(r[1]) for r in rows])   # widen to the longest name — never cut it
if tsv: print("\t".join(["state", "name", "pid", "age_m", "idle_m", "acct", "cwd"]))
else: print(f"{'state':6} {'name':{w}} {'pid':>7} {'age_m':>6} {'idle_m':>6} {'acct':4}  cwd")
for alive, name, pid, age, idle, kind, cwd in rows:
    state = "live" if alive else "DEAD"
    if tsv: print("\t".join([state, re.sub(r"[\t\r\n]+", " ", name), str(pid), str(age), str(idle), acct.get(name, "-"), cwd]))
    else: print(f"{state:6} {name:{w}} {pid:>7} {age:>6} {idle:>6} {acct.get(name, '-'):4}  {cwd}")
PY
