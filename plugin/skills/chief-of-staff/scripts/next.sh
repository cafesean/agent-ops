#!/usr/bin/env bash
# The plan daemon. Reads this machine's task files (and legacy mission files) and says, per worker, what is
# happening now, what comes next and what blocks it — so the plan survives any Claude session dying. Runs
# from a scheduler (cron / launchd / Hermes add-on) every 20 min, and from the chief SWEEP; the chief reads
# this machine's block in Outstanding.md instead of scroll-back.
#   next.sh                write this machine's Outstanding.md block + STATE.md "next.sh" line; print a summary
#   next.sh --alert        scheduled mode: print ONLY missions that newly flipped to blocked/died
#                          (deduped via $COS_DIR/.next-alert-state.json); empty stdout = nothing new.
#                          With the optional Hermes add-on, stdout goes to chat (e.g. Telegram).
#   next.sh --src NAME     label the daemon.log line (default: manual)
#   next.sh --no-queue     skip queue-run.sh (default: run it first, so queued tasks spawn every 20 min)
# Tasks: tasks/<name>.md frontmatter is read exactly like a mission file (a task overrides a same-name
#   mission); its `## Reports` lines are its inbox; its status/where/account replace the LEDGER row. Open tasks
#   addressed to this machine show as "Queue". The run stamps `- <prefix> next.sh: …` under STATE.md → Last verified.
# NEXT.md opens with "⛔ Needs you": every open ask from every mission's `asks:` block, sorted
#   TEST → APPROVE → DECIDE. An ask waiting > $COS_PARK_MIN min (default 50) shows 💤 — park that worker.
#   Outstanding.md embeds NEXT.md, so the lane shows there too. --alert also pages each NEW open ask.
# Inputs: missions/*.yaml (schema: references/orchestration.md → Mission file), the story_list.json each
#   mission points at, inbox/<worker>.md (latest status line), LEDGER.md (last row per worker),
#   sessions.sh (live pids). Read-only on all of them.
# Exit 1 when a mission file fails to parse (NEXT.md is still written, with the broken file flagged).
# Per machine: plans ONLY this machine's missions (cos-env.sh cos_own: prefix $COS_MACHINE_PREFIX; the host
#   also owns remote + legacy names) and writes them into ITS block of $COS_OUTSTANDING, between
#   `<!-- cos:next:<prefix> -->` markers — never another machine's block. The host (COS_HOST_PREFIX) also writes
#   NEXT.md (compat). A non-host machine with 0 own mission files writes nothing and says why (exit 0).
# Stale state: LEDGER STARTED rows whose mission is closed, asks open > 1 day; host block also flags
#   goals still `confirm?` and the brief check — same ONE Thing 3 briefs in a row, or its parent goal `done`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"
ALERT=0 SRC=manual QUEUE=1
while [ $# -gt 0 ]; do case "$1" in
  --alert) ALERT=1; shift;; --src) SRC="$2"; shift 2;; --no-queue) QUEUE=0; shift;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; done
mkdir -p "$COS_DIR/missions"
# The queue first: open tasks addressed to this machine get claimed + spawned (queue-run.sh prints only changes).
[ "$QUEUE" = 0 ] || [ "${COS_QUEUE:-1}" = 0 ] || "$HERE/queue-run.sh" 2>/dev/null || true
SESS=$("$HERE/sessions.sh" --tsv 2>/dev/null || true)
export COS_LIB="$HERE/lib"
export COS_REMOTE_MACHINE_PREFIX="${COS_REMOTE_MACHINE_PREFIX:-}" COS_GOALS="${COS_GOALS:-$COS_DIR/GOALS.md}" COS_OUTSTANDING="${COS_OUTSTANDING:-}"
cos_python - "$COS_DIR" "$ALERT" "$SRC" "$SESS" <<'PY'
import json, os, re, sys, glob, datetime as dt
sys.path.insert(0, os.environ["COS_LIB"]); import tasks as T
cosdir, alert, src, sess = sys.argv[1], sys.argv[2] == "1", sys.argv[3], sys.argv[4]
now = dt.datetime.now()
PFX, HOST, RPFX = os.environ["COS_PREFIX"], os.environ["COS_HOST_PREFIX"], os.environ.get("COS_REMOTE_MACHINE_PREFIX", "")
IS_HOST = PFX == HOST
def own(w):   # mirror of cos-env.sh cos_own
    m = re.match(r"([a-z])-", w or "")
    if not m: return IS_HOST
    return m.group(1) == PFX or (IS_HOST and bool(RPFX) and m.group(1) == RPFX)
DONE_ST = {"code_complete", "done", "complete", "completed", "verified", "passed", "shipped", "merged"}
SKIP_ST = {"cancelled", "canceled", "dropped", "superseded", "skipped", "wontfix"}
ACTIVE_ST = {"in_progress", "active", "building", "wip", "in-progress"}

PARK_MIN = int(os.environ.get("COS_PARK_MIN") or 50)
# ---- minimal YAML subset (stdlib only): top-level scalars, flow lists, block lists of flat maps or scalars ----
def scalar(v, where):
    v = v.strip()
    if v in ("", "~", "null"): return None
    if v.startswith("["):
        if not v.endswith("]"): raise ValueError(f"{where}: unclosed [")
        inner = v[1:-1].strip()
        return [scalar(x, where) for x in re.findall(r'"(?:[^"\\]|\\.)*"|\'[^\']*\'|[^,]+', inner) if x.strip()] if inner else []
    if v.startswith('"'):
        try: return json.loads(v)
        except Exception: raise ValueError(f"{where}: bad double-quoted string")
    if v.startswith("'"):
        if not v.endswith("'") or len(v) < 2: raise ValueError(f"{where}: bad single-quoted string")
        return v[1:-1].replace("''", "'")
    if v in ("true", "false"): return v == "true"
    if re.fullmatch(r"-?\d+", v): return int(v)
    return v
def strip_comment(line):
    q = None
    for i, c in enumerate(line):
        if q:
            if c == q: q = None
        elif c in "\"'": q = c
        elif c == "#" and (i == 0 or line[i-1] in " \t"): return line[:i]
    return line
def load_yaml(path):
    doc, cur_list, cur_item = {}, None, None
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = strip_comment(raw.rstrip("\n")).rstrip()
        if not line.strip(): continue
        where = f"{os.path.basename(path)}:{n}"
        if "\t" in raw[:len(raw) - len(raw.lstrip())]: raise ValueError(f"{where}: tab indent")
        ind = len(line) - len(line.lstrip())
        body = line.strip()
        if ind == 0:
            m = re.fullmatch(r"([A-Za-z_][\w-]*):(?:\s+(.*))?", body)
            if not m: raise ValueError(f"{where}: expected 'key: value'")
            k, v = m.group(1), m.group(2)
            if v is None or v == "":
                doc[k] = []; cur_list, cur_item = doc[k], None
            else:
                doc[k] = scalar(v, where); cur_list = cur_item = None
            continue
        if cur_list is None: raise ValueError(f"{where}: indented line outside a list")
        if body.startswith("- "):
            rest = body[2:].strip()
            if rest[:1] in "\"'" or not re.fullmatch(r"([A-Za-z_][\w-]*):(?:\s+(.*))?", rest):
                cur_list.append(scalar(rest, where)); cur_item = None; continue   # scalar item, e.g. decisions
            cur_item = {}; cur_list.append(cur_item); body = rest
        elif cur_item is None: raise ValueError(f"{where}: list item must start with '- '")
        m = re.fullmatch(r"([A-Za-z_][\w-]*):(?:\s+(.*))?", body)
        if not m: raise ValueError(f"{where}: expected 'key: value' in list item")
        cur_item[m.group(1)] = scalar(m.group(2) or "", where)
    return doc

# ---- sources ----
def inbox_state(path):
    st = {"status": None, "ts": None, "bullets": [], "mtime": None}
    if not os.path.exists(path): return st
    st["mtime"] = dt.datetime.fromtimestamp(os.path.getmtime(path))
    text = open(path, encoding="utf-8", errors="ignore").read()
    if "\n" + T.REPORTS in text: text = text[text.index("\n" + T.REPORTS) + 1:]   # task file: reports only
    lines = text.split("\n")
    for i, l in enumerate(lines):
        m = re.match(r"[\s*]*status:\s*\**\s*(STARTED|WORKING|BLOCKED|DONE|FAILED)\b\s*(\d{4}-\d\d-\d\d \d\d:\d\d)?", l)
        if m:
            st["status"], st["bullets"] = m.group(1), []
            try: st["ts"] = dt.datetime.strptime(m.group(2), "%Y-%m-%d %H:%M") if m.group(2) else None
            except ValueError: st["ts"] = None
            for b in lines[i+1:]:
                if re.match(r"[\s*]*status:\s*\**\s*(STARTED|WORKING|BLOCKED|DONE|FAILED)\b", b): break
                if b.strip().startswith(("-", "*")): st["bullets"].append(b.strip().lstrip("-* ").strip())
    return st
ledger = {}
lp = os.path.join(cosdir, "LEDGER.md")
if os.path.exists(lp):
    for l in open(lp, encoding="utf-8", errors="ignore"):
        c = [x.strip() for x in l.strip().strip("|").split("|")]
        if len(c) >= 7 and re.match(r"\d{4}-\d\d-\d\d", c[0]):
            new = len(c) >= 8 and re.fullmatch(r"[a-z][a-z0-9]{0,5}", c[7] or "") is not None   # 0.9.0 account column
            ledger[c[1]] = {"where": c[2], "status": (c[6] if new else " ".join(c[6:])).strip(), "account": c[7] if new else None}
live = {}
for l in sess.splitlines()[1:]:
    p = l.split("\t")   # sessions.sh --tsv: full name
    if len(p) >= 5 and p[0] == "live": live[p[1]] = p[2]
def stories(path):
    d = json.load(open(path, encoding="utf-8"))
    ss = d.get("stories", []) if isinstance(d, dict) else d
    ss = [s for s in ss if isinstance(s, dict) and str(s.get("status", "")).lower() not in SKIP_ST]
    done = [s for s in ss if str(s.get("status", "")).lower() in DONE_ST]
    open_ = [s for s in ss if s not in done]
    nxt = next((s for s in open_ if str(s.get("status", "")).lower() in ACTIVE_ST), open_[0] if open_ else None)
    return len(done), len(ss), nxt
def when(v):
    for f in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M:%S"):
        try: return dt.datetime.strptime(str(v).strip(), f)
        except (ValueError, TypeError): pass
    return None
def short(s, n):
    s = re.sub(r"\s+", " ", str(s or "")).replace("|", "/").strip()
    return s if len(s) <= n else s[:n-1] + "…"

# ---- evaluate missions ----
files = sorted(glob.glob(os.path.join(cosdir, "missions", "*.yaml")))
missions, broken = {}, []
for f in files:
    try:
        m = load_yaml(f)
        if not m.get("worker"): raise ValueError(f"{os.path.basename(f)}: missing worker")
        m["_file"] = f; missions[m["worker"]] = m
    except (ValueError, OSError, UnicodeDecodeError) as e:
        if own(os.path.basename(f)[:-5]): broken.append(str(e))
queue = []
for tp, fm in T.list_tasks(cosdir):   # task files — override same-name missions + LEDGER rows
    w, st = fm.get("name"), str(fm.get("status") or "")
    if st.startswith("broken"):
        if own(w): broken.append(f"tasks/{w}.md: {st}")
        continue
    if st == "open":
        if own(f"{fm.get('to') or ''}-x"): queue.append(fm)
        continue
    fm = dict(fm); fm["worker"] = w; fm["inbox"] = tp; fm["_file"] = tp
    fm["status"] = {"claimed": "active", "running": "active", "failed": "stopped"}.get(st, st)
    missions[w] = fm
    if fm.get("where") or fm.get("started"):
        ledger[w] = {"where": str(fm.get("where") or ""), "status": st, "account": fm.get("account")}
all_missions = missions
missions = {w: m for w, m in all_missions.items() if own(w)}
if not missions and not broken and not IS_HOST:
    print(f"next.sh: 0 {PFX}-* mission files on this machine (host = {HOST}) — nothing to plan; Outstanding/NEXT untouched. "
          f"Plan this machine's workers by spawning them here; the host's missions are planned on the host.", file=sys.stderr)
    if not alert: print(f"skip src={src} prefix={PFX} own_missions=0 (non-host guard)")
    sys.exit(0)
def mission_done(m, ib):
    return str(m.get("status") or "").lower() in ("done", "parked", "stopped") or ib["status"] == "DONE"
rows, asks = [], []
ASK_ORDER = {"TEST": 0, "APPROVE": 1, "DECIDE": 2}
for w, m in missions.items():
    ib = inbox_state(os.path.join(cosdir, m.get("inbox") or f"inbox/{w}.md"))
    led = ledger.get(w, {})
    r = {"w": w, "goal": m.get("parent_goal") or "?", "task": m.get("task_goal") or "—", "reasons": [], "kind": "ok",
         "mstatus": str(m.get("status") or "active").lower(), "acct": led.get("account") or m.get("account")}
    # slices (status derived from story_list when linked)
    slices = list(m.get("slices") or [])
    if not slices and m.get("story_list"):
        slices = [{"id": "build", "title": "stories code-complete", "status": "active", "story_list": m["story_list"]}]
    prog, story_next = None, None
    for s in slices:
        sl = s.get("story_list")
        if sl:
            try:
                d, t, nx = stories(sl)
                s["_prog"] = f"{d}/{t}"
                s["status"] = "done" if t and d == t else ("active" if d or str(s.get("status")) == "active" else s.get("status") or "pending")
                s["_next"] = f"{nx.get('id', '')} {nx.get('title', '')}".strip() if nx else None
            except Exception as e:
                s["_prog"] = "story_list?"; r["reasons"].append(f"story_list unreadable: {short(sl, 50)}")
    sstat = {s.get("id"): str(s.get("status") or "pending").lower() for s in slices}
    cur = next((s for s in slices if str(s.get("status")).lower() == "active"), None) \
        or next((s for s in slices if str(s.get("status")).lower() not in ("done", "dropped")), None)
    later = [s for s in slices if s is not cur and str(s.get("status")).lower() not in ("done", "dropped")]
    if cur:
        prog = cur.get("_prog")
        unmet = [x for x in (cur.get("depends_on") or []) if sstat.get(x) != "done"]
        if unmet: r["reasons"].append("slice waits on " + ", ".join(unmet)); r["kind"] = "blocked"
    for dep in m.get("depends_on_missions") or []:
        dm = all_missions.get(dep)
        if dm is None: r["reasons"].append(f"waits on mission {dep} (no mission file)"); r["kind"] = "blocked"
        elif not mission_done(dm, inbox_state(os.path.join(cosdir, dm.get("inbox") or f"inbox/{dep}.md"))):
            r["reasons"].append(f"waits on mission {dep}"); r["kind"] = "blocked"
    for a in m.get("asks") or []:
        if not isinstance(a, dict) or str(a.get("status") or "open").lower() != "open": continue
        cls = str(a.get("class") or "?").upper()
        asks.append({"w": w, "goal": r["goal"], "id": a.get("id") or "?", "cls": cls, "what": a.get("what") or "—",
                     "asked": when(a.get("asked")), "not_before": when(a.get("not_before")), "steps": a.get("steps"),
                     "options": a.get("options"), "dflt": a.get("default_if_silent"), "link": a.get("session_link"),
                     "parked": r["mstatus"] == "parked"})
        r["reasons"].append(f"⛔ waits on you: {asks[-1]['id']} {cls}")
    done = mission_done(m, ib)
    last = ib["bullets"][0] if ib["bullets"] else ""
    if done:
        r["kind"] = "done"
        r["now"] = f"✅ {'DONE ' + ib['ts'].strftime('%m-%d %H:%M') if ib['status'] == 'DONE' and ib['ts'] else r['mstatus']}"
        if ib["status"] == "DONE" and r["mstatus"] == "active": r["now"] += " · verify, then set mission status: done"
        if m.get("handoff"): r["now"] += f" → handoff: {short(m['handoff'], 120)}"
    else:
        is_remote = led.get("where", "").startswith("remote")
        led_closed = bool(re.match(r"(STOPPED|ENDED|CLOSED|DONE|FAILED)", led.get("status", ""), re.I)) or "CLOSED" in led.get("status", "")
        if ib["status"] == "BLOCKED":
            need = next((b for b in ib["bullets"] if re.search(r"NEEDS|owner|chief", b)), last)
            r["reasons"].insert(0, "BLOCKED: " + short(need, 110)); r["kind"] = "blocked"
        if ib["status"] in ("STARTED", "WORKING", "BLOCKED") and not is_remote and w not in live:
            r["reasons"].insert(0, "worker gone — LEDGER " + short(led.get("status") or "no row", 30) + " → spawn successor from mission"
                                if led_closed else "worker died (no live pid) → spawn successor from mission")
            r["kind"] = "died"
        elif ib["status"] in ("STARTED", "WORKING") and ib["mtime"]:
            age = int((now - ib["mtime"]).total_seconds() // 60)
            hb = int(m.get("heartbeat_min") or 60)
            if age > hb:
                r["reasons"].append(f"stale: inbox quiet {age}m > {hb}m heartbeat")
                if r["kind"] == "ok": r["kind"] = "stale"
        if ib["ts"] and ib["ts"] > now + dt.timedelta(minutes=15):
            r["reasons"].append(f"inbox time {ib['ts']:%H:%M} is ahead of the clock")
        emoji = {"died": "💀", "blocked": "⏸", "stale": "🟡"}.get(r["kind"], "🔨")
        r["now"] = f"{emoji} {ib['status'] or 'no inbox'}" + (f" · {prog}" if prog else "") + (f" · {short(last, 90)}" if last else "")
    # next step
    nx = None
    if not done:
        if cur and cur.get("_next"): nx = f"{cur.get('title') or cur.get('id')}: next {short(cur['_next'], 70)}"
        elif cur and cur.get("status") != "active": nx = f"start {cur.get('title') or cur.get('id')}"
        elif later: nx = f"then {later[0].get('title') or later[0].get('id')}" + (f" ({later[0].get('owner')})" if later[0].get("owner") else "")
        elif cur: nx = f"finish {cur.get('title') or cur.get('id')}"
        if later and nx and not nx.startswith("then"):
            nx += f" → then {later[0].get('title') or later[0].get('id')}" + (f" ({later[0].get('owner')})" if later[0].get("owner") else "")
    r["next"] = nx or "—"
    rows.append(r)

order = {"died": 0, "blocked": 1, "stale": 2, "ok": 3, "done": 4}
rows.sort(key=lambda r: (order[r["kind"]], r["w"]))
act = [r for r in rows if r["kind"] != "done"]
bad = [r for r in act if r["kind"] in ("died", "blocked")]
stale = [r for r in act if r["kind"] == "stale"]
head = "🔴" if bad or broken else ("🟡" if stale else "🟢")
verdict = []
if bad: verdict.append(f"{len(bad)} blocked/died")
if stale: verdict.append(f"{len(stale)} stale")
if broken: verdict.append(f"{len(broken)} mission file broken")
if asks: verdict.append(f"⛔ {len(asks)} for you")
# ---- 🧹 stale state: nothing closes old state by itself, so flag it every run ----
stale_st = []
for w, led in ledger.items():
    if not own(w) or not re.match(r"(STARTED|WORKING|QUEUED|running|claimed)\b", led.get("status", ""), re.I): continue
    m = all_missions.get(w)
    ms = str((m or {}).get("status") or "").lower()
    ibs = inbox_state(os.path.join(cosdir, (m or {}).get("inbox") or f"inbox/{w}.md"))["status"]
    ibp = os.path.join(cosdir, (m or {}).get("inbox") or f"inbox/{w}.md")
    quiet_d = (now - dt.datetime.fromtimestamp(os.path.getmtime(ibp))).days if os.path.exists(ibp) else 99
    if ms not in ("done", "parked", "stopped") and ibs not in ("DONE", "FAILED") and w not in live \
            and not led.get("where", "").startswith("remote") and quiet_d >= 1 and ms != "active":
        stale_st.append(f"LEDGER `{w}` still {led['status'].split()[0]}, no live pid, quiet {quiet_d}d → `stop.sh {w} STOPPED` (then archive.sh)")
        continue
    if ms in ("done", "parked", "stopped") or ibs in ("DONE", "FAILED"):
        stale_st.append(f"{'task' if led['status'] in ('running', 'claimed') else 'LEDGER'} `{w}` still {led['status'].split()[0]} but " + (f"mission is {ms}" if ms in ("done", "parked", "stopped") else f"inbox says {ibs}") + f" → `stop.sh {w} {'DONE' if ibs == 'DONE' or ms == 'done' else 'STOPPED'}`")
for a in asks:
    if a["asked"] and now - a["asked"] > dt.timedelta(days=1):
        stale_st.append(f"ask `{a['w']}:{a['id']}` open {(now - a['asked']).days}d — answer, withdraw, or park the worker")
goals = {}
gp = os.environ.get("COS_GOALS") or os.path.join(cosdir, "GOALS.md")
if IS_HOST and os.path.exists(gp):
    gid = None
    for l in open(gp, encoding="utf-8", errors="ignore"):
        h = re.match(r"### (\S+) · ", l)
        if h: gid = h.group(1); goals[gid] = ""; continue
        s = re.match(r"status:\s*(.*)", l)
        if gid and s and not goals[gid]: goals[gid] = s.group(1).strip()
    conf = [g for g, s in goals.items() if s.startswith("confirm?")]
    if conf: stale_st.append(f"{len(conf)} goal{'s' * (len(conf) != 1)} still `confirm?` in GOALS.md ({', '.join(conf)}) — the owner confirms or parks each, with a reason")
    bf = sorted(f for f in glob.glob(os.path.join(cosdir, "briefs", "*.md")) if re.search(r"\d{4}-\d\d-\d\d-\d{4}\.md$", f))[-3:]
    ones = []
    for f in bf:
        for l in open(f, encoding="utf-8", errors="ignore"):
            o = re.match(r"^[^A-Za-z]*ONE Thing:\**\s*(.+)", l)
            if o: ones.append(o.group(1)); break
    def norm(t): return re.sub(r"\s+", " ", re.split(r"\s+—\s+why", t.replace("**", ""))[0]).strip().lower()
    if len(ones) == 3 and len({norm(o) for o in ones}) == 1:
        stale_st.append(f"brief check: same ONE Thing 3 briefs in a row ({short(norm(ones[-1]), 70)}) — finish it, re-pick, or say why it holds")
    if ones:
        pid = re.search(r"\[([A-Z]\w*)\??\]", ones[-1])
        if pid and goals.get(pid.group(1), "").startswith("done"):
            stale_st.append(f"brief check: ONE Thing's parent goal {pid.group(1)} is already `done` — pick a live goal")
if stale_st: verdict.append(f"🧹 {len(stale_st)} stale")
L = [f"**{head} NEXT {PFX} {now:%H:%M}** — {len(act)} active mission{'s' * (len(act) != 1)} · " + (" · ".join(verdict) or "nothing blocked"), ""]
# ---- ⛔ Needs you: open asks, TEST → APPROVE → DECIDE, oldest first ----
asks.sort(key=lambda a: (ASK_ORDER.get(a["cls"], 3), a["asked"] or now, a["w"]))
if asks:
    L += [f"## ⛔ Needs you — {len(asks)} open", "", "| | Worker | Ask | Waiting | If silent | Open |", "|---|---|---|---|---|---|"]
    for a in asks:
        icon = {"TEST": "🧪", "APPROVE": "✅", "DECIDE": "🧭"}.get(a["cls"], "❓")
        what = a["what"]
        if a["not_before"] and a["not_before"] > now: what += f" (after {a['not_before']:%H:%M})"
        if a["cls"] == "TEST" and a["steps"]: what += f" — steps: {a['steps']}"
        if a["cls"] == "DECIDE" and a["options"]: what += f" — {a['options']}"
        mins = int((now - a["asked"]).total_seconds() // 60) if a["asked"] else None
        wait = (f"{mins} min" if mins is not None else "?") + (" · 💤 parked" if a["parked"] else
                (f" · 💤 park it (> {PARK_MIN} min)" if mins is not None and mins > PARK_MIN else " · live"))
        L.append("| " + " | ".join([f"{icon} {a['cls']}", f"{a['w']} [{a['goal']}]", short(what, 200), wait,
                                    short(a["dflt"] or "blocks", 60), f"[session]({a['link']})" if a["link"] else "pane"]) + " |")
    L.append("")
L += ["| Worker | Task goal | Now | Next | Blocked by |", "|---|---|---|---|---|"]
for r in act:
    b = "**" if r["kind"] in ("died", "blocked") else ""
    cells = [f"{r['w']} [{r['goal']}]" + (f" ·{r['acct']}" if r.get("acct") else ""), short(r["task"], 70), short(r["now"], 150), short(r["next"], 120), short("; ".join(r["reasons"]) or "—", 160)]
    L.append("| " + " | ".join(f"{b}{c}{b}" if c and c != "—" else c for c in cells) + " |")
if not act: L.append("| — | no active missions | — | — | — |")
for e in broken: L.append(f"\n⚠ mission file broken: `{e}`")
dn = [r for r in rows if r["kind"] == "done"]
if dn:
    L += ["", "**Closed:** " + " · ".join(f"{r['w']} [{r['goal']}] {r['now']}" for r in dn)]
if queue:
    L += ["", f"**📥 Queue — {len(queue)} open for {PFX}** (queue-run.sh claims + spawns them every run)"]
    for q in queue: L.append(f"- `{q.get('name')}` [{q.get('parent_goal') or '?'}] {short(q.get('task_goal') or '', 80)}" + (f" — {short(q.get('queue_note'), 90)}" if q.get("queue_note") else ""))
if stale_st: L += ["", f"**🧹 Stale state — {len(stale_st)}**", *[f"- {x}" for x in stale_st]]
L += ["", f"_updated {now:%Y-%m-%d %H:%M} by next.sh on {PFX} ({src}) — overwritten every run; edit `tasks/<name>.md` frontmatter, not this block. Sources: tasks · story_list.json · sessions.sh (+ legacy missions/inbox/LEDGER)_"]
def write(path, text):
    tmp = os.path.join(os.path.dirname(path), "." + os.path.basename(path) + ".tmp")
    open(tmp, "w", encoding="utf-8").write(text); os.replace(tmp, path)
if IS_HOST and os.path.exists(os.path.join(cosdir, "NEXT.md")):   # compat until archive.sh retires NEXT.md
    write(os.path.join(cosdir, "NEXT.md"), "\n".join(L) + "\n")
# This machine's block in Outstanding.md — only between its own markers; other machines' blocks are never touched.
op = os.environ.get("COS_OUTSTANDING")
if op:
    o0, o1 = f"<!-- cos:next:{PFX} -->", f"<!-- /cos:next:{PFX} -->"
    blk = o0 + "\n" + "\n".join(L) + "\n" + o1
    doc = open(op, encoding="utf-8").read() if os.path.exists(op) else f"# Outstanding\n\n"
    if o0 in doc and o1 in doc:
        doc = doc[:doc.index(o0)] + blk + doc[doc.index(o1) + len(o1):]
    else:
        ends = [mm.end() for mm in re.finditer(r"<!-- /cos:next:[a-z] -->", doc)]
        emb = re.search(r"(?m)^!\[\[[^\]]*NEXT\]\]\s*$", doc)
        if ends: doc = doc[:ends[-1]] + "\n\n" + blk + "\n" + doc[ends[-1]:]
        elif emb: doc = doc[:emb.start()] + blk + doc[emb.end():]
        else:
            h = re.search(r"(?m)^# .*$", doc)
            doc = (doc[:h.end()] + "\n\n" + blk + doc[h.end():]) if h else blk + "\n\n" + doc
    write(op, doc)

# ---- alerts: only NEW flips to blocked/died, deduped by state file ----
out = []
if alert:
    sp = os.path.join(cosdir, ".next-alert-state.json")
    try: prev = json.load(open(sp))
    except Exception: prev = {}
    cur_state = {r["w"]: r["kind"] for r in rows}
    cur_state["_asks"] = sorted(f"{a['w']}:{a['id']}" for a in asks)
    seen = set(prev.get("_asks") or [])
    for a in asks:
        if f"{a['w']}:{a['id']}" not in seen:
            out.append(f"⛔ {a['w']} [{a['goal']}] {a['cls']}: {short(a['what'], 140)} — if silent: {short(a['dflt'] or 'blocks', 60)}")
    for r in rows:
        if r["kind"] in ("died", "blocked") and prev.get(r["w"]) != r["kind"]:
            out.append(f"{'💀' if r['kind'] == 'died' else '⏸'} {r['w']} [{r['goal']}] {r['kind'].upper()} — {short('; '.join(r['reasons']), 200)}")
    if broken:
        cur_state["_broken"] = broken
        if prev.get("_broken") != broken: out.append("⚠ chief plan daemon: mission file broken — " + "; ".join(broken))
    if out: out.append(f"→ NEXT.md {now:%H:%M}")
    json.dump(cur_state, open(sp + ".tmp", "w")); os.replace(sp + ".tmp", sp)
summary = f"{'FAIL' if broken else 'ok'} src={src} prefix={PFX}{'(host)' if IS_HOST else ''} stale_state={len(stale_st)} queued={len(queue)} missions={len(rows)} active={len(act)} blocked_or_died={len(bad)} stale={len(stale)} asks={len(asks)} alerts={max(len(out) - 1, 0)}"
if os.path.exists(os.path.join(cosdir, "daemon.log")):   # compat until archive.sh retires it; proof of run = STATE.md line
    with open(os.path.join(cosdir, "daemon.log"), "a", encoding="utf-8") as f:
        f.write(f"{now:%Y-%m-%d %H:%M:%S} {summary}\n")
# STATE.md → Last verified: this machine's next.sh line, replaced in place (never prepended).
sp_ = os.path.join(cosdir, "STATE.md")
if os.path.exists(sp_):
    S = open(sp_, encoding="utf-8").read().split("\n")
    if "## Last verified" in S:
        line = f"- {PFX} next.sh: {now:%Y-%m-%d %H:%M} {'FAIL' if broken else 'ok'} — {len(act)} active · {len(bad)} blocked/died · {len(asks)} asks · {len(queue)} queued · {len(stale_st)} stale"
        i = next((n for n, l in enumerate(S) if l.startswith(f"- {PFX} next.sh:")), None)
        if i is None:
            j = S.index("## Last verified") + 1
            while j < len(S) and S[j].startswith("- "): j += 1
            S.insert(j, line)
        else: S[i] = line
        write(sp_, "\n".join(S))
if alert: print("\n".join(out))
else: print(summary + f" → {op or os.path.join(cosdir, 'NEXT.md')}")
if broken: print("; ".join(broken), file=sys.stderr); sys.exit(1)
PY
