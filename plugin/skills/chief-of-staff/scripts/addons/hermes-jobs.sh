#!/usr/bin/env bash
# Monitor Hermes cron jobs. Hermes owns them; the chief only watches and reports.
# Records each new run into $COS_DIR/hermes-runs.tsv (deduped by job+last_run_at) so
# success rate builds up over time, then prints enabled jobs + flags.
#   hermes-jobs.sh          table + flags
#   hermes-jobs.sh --flags  flags only (empty = healthy)
#   hermes-jobs.sh --new    only flags not seen last run (for sweeps → Telegram)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../cos-env.sh"
[ -n "${COS_HERMES:-}" ] || { echo "addon hermes not configured, skipping"; exit 0; }
cos_python - "$COS_DIR/hermes-runs.tsv" "${1:-}" "$COS_DIR/hermes-flags.last" <<'PY'
import json, os, sys, datetime as dt
log, mode, lastf = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(os.path.expanduser("~/.hermes/cron/jobs.json")))
jobs = d if isinstance(d, list) else d.get("jobs", d)
if isinstance(jobs, dict): jobs = list(jobs.values())
now = dt.datetime.now(dt.timezone.utc)
seen = set()
if os.path.exists(log):
    for line in open(log):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3: seen.add((p[0], p[1]))
with open(log, "a") as f:
    for j in jobs:
        if j.get("last_run_at") and (j["id"], j["last_run_at"]) not in seen:
            err = (j.get("last_error") or j.get("last_delivery_error") or "").replace("\t", " ").replace("\n", " ")[:160]
            f.write(f"{j['id']}\t{j['last_run_at']}\t{j.get('last_status')}\t{j.get('name')}\t{err}\n")
hist = {}
cut = now - dt.timedelta(days=14)
for line in open(log):
    p = line.rstrip("\n").split("\t")
    if len(p) < 3: continue
    try: t = dt.datetime.fromisoformat(p[1])
    except Exception: continue
    if t >= cut: hist.setdefault(p[0], []).append(p[2])
def ts(s):
    try: return dt.datetime.fromisoformat(s)
    except Exception: return None
flags, rows = [], []
for j in jobs:
    if not j.get("enabled"): continue
    runs = hist.get(j["id"], [])
    ok = sum(1 for r in runs if r == "ok")
    rate = f"{ok}/{len(runs)}" if runs else "-"
    nxt = ts(j.get("next_run_at") or "")
    st = j.get("last_status") or "never"
    name = j.get("name") or j["id"]
    if st not in ("ok", "never"):
        err = (j.get("last_error") or j.get("last_delivery_error") or "")[:110]
        flags.append(f"FAIL {name} ({j['id']}): {st} — {err}")
    if nxt and nxt < now - dt.timedelta(minutes=30):
        flags.append(f"MISSED {name}: next_run_at {j['next_run_at'][:16]} is past — scheduler stalled?")
    if j.get("last_delivery_error"):
        flags.append(f"DELIVERY {name}: {j['last_delivery_error'][:110]}")
    rows.append((name[:38], j.get("schedule_display") or "", (j.get("last_run_at") or "-")[:16], st[:14], rate))
uniq = list(dict.fromkeys(flags))
# key = first 60 chars so a changing error tail does not re-alert
key = lambda x: x[:60]
prev = set(open(lastf).read().splitlines()) if os.path.exists(lastf) else set()
open(lastf, "w").write("\n".join(key(x) for x in uniq))
if mode == "--new":
    for fl in uniq:
        if key(fl) not in prev: print(fl)
    sys.exit(0)
if mode != "--flags":
    print(f"{'job':38} {'schedule':16} {'last run':16} {'status':14} ok/14d")
    for r in rows: print(f"{r[0]:38} {r[1]:16} {r[2]:16} {r[3]:14} {r[4]}")
    paused = [j.get("name") for j in jobs if not j.get("enabled")]
    print(f"paused ({len(paused)}): " + ", ".join(p or "?" for p in paused))
for fl in uniq: print(fl)
PY
