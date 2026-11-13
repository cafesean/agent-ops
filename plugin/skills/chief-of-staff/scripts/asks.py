#!/usr/bin/env python3
"""asks.py — keep every NEEDS-YOU item (an open ask to the user) true. An ask that stopped being valid but keeps
asking wastes the user's time working out whether it still matters.

An ask is SHOWN to the user only when it is fresh: `checked:` (or `asked:`) within $COS_ASK_FRESH_H hours (default 24).
Older asks drop to the RE-CHECK list until a session re-checks them. Ask keys this script reads/writes:
  check:        shell command, run from $COS_DIR with a 15 s timeout. Exit 0 = the ask is NO LONGER needed (done,
                answered, superseded) → closed stale. Exit 1 = still needed → checked: now. Other exit = broken check
                (check_error:, ask left as is). Write it so a broken command never exits 0 (`grep -q`, `test`, `gh … | grep -q`).
  evidence:     plain line naming what to look at when no command can tell (re-checked by hand: `asks.py verify`).
  checked:      when a check or a session last proved the ask still true and needed.
  status:       open | answered | withdrawn | stale (+ stale_reason:, closed:).
hooks/ask-guard.py denies a new ask without a check: or evidence: line.

CLI:
  asks.py list [--all] [--json]     open asks of this machine's LIVE tasks (closed/superseded tasks never show), duplicates
                                    folded; FRESH first, then RE-CHECK. --all = every prefix.
  asks.py check [FILE...]           run `check:` of every open ask (default: this machine's live tasks).
  asks.py verify FILE ID [NOTE]     you looked at the evidence THIS turn and it still holds → checked: now (+ evidence).
  asks.py close FILE ID REASON      status: stale + stale_reason + closed: now (done, answered, superseded, moot).
  asks.py queue [--json]            the ONE user queue: fresh open asks, hard gate (money/customer/delete/secret/legal…)
                                    first, then blockers, then TEST, then oldest; max COS_USER_QUEUE_MAX (5) + "more:" line.
  asks.py sweep [--dry-run]         close open asks of closed or superseded tasks (status stopped|done|failed, `handoff:
                                    superseded by`, or a task that `continues:` it) — their answer reaches no one. Asks
                                    naming money/customer/delete/secret/legal/ad account on a task with NO successor are
                                    listed as ORPHAN instead (re-file on a live task if still needed). Then runs check.
Run `sweep` from the chief's periodic loop (e.g. next.sh; COS_ASK_SWEEP=0 = off there).
Env: COS_DIR (else from the agent-ops config via cos-env.sh), COS_PREFIX / COS_MACHINE_PREFIX (this machine's task prefix).
"""
import datetime as dt, json, os, re, subprocess, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import tasks as T  # noqa: E402

def _cos_env(var, default=""):
    """A value from the agent-ops config (cos-env.sh), for runs outside a configured shell."""
    try:
        out = subprocess.run(["bash", "-c", '. "$1" >/dev/null 2>&1; printf %s "${!2}"', "_",
                              os.path.join(os.path.dirname(os.path.abspath(__file__)), "cos-env.sh"), var],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return out or default
    except Exception:
        return default


COSDIR = os.environ.get("COS_DIR") or _cos_env("COS_DIR", os.path.expanduser("~/agent-ops/state"))
PFX = os.environ.get("COS_PREFIX") or os.environ.get("COS_MACHINE_PREFIX") or "m"
FRESH_H = float(os.environ.get("COS_ASK_FRESH_H") or 24)
CLOSED = ("stopped", "done", "failed")
HARD = re.compile(r"(\$|\bmoney\b|\bpay|\bpric|\bcredits?\b|\bbilling\b|\bdelete|\bcustomers?\b|"
                  r"\bad account|\blegal\b|\bsecret|\brotat)", re.I)


if not hasattr(T, "set_ask"):   # older lib/tasks.py: in-place ask editing lives here until tasks.py carries it
    def _ask_spans(fm):
        """-> [(start, end, item_indent, id)] for each item of the top-level `asks:` block list."""
        i = next((n for n, l in enumerate(fm) if re.match(r"asks:\s*$", l)), None)
        if i is None: return []
        out, j = [], i + 1
        while j < len(fm) and (not fm[j].strip() or fm[j][:1] in " \t"):
            m = re.match(r"(\s+)- ", fm[j])
            if m:
                k = j + 1
                while k < len(fm) and (not fm[k].strip() or (fm[k][:1] in " \t" and not re.match(re.escape(m.group(1)) + r"- ", fm[k]))): k += 1
                iid = next((re.sub(r"^\s*(- )?id:\s*", "", fm[n]).strip().strip("\"'") for n in range(j, k)
                            if re.match(r"\s*(- )?id:\s", fm[n])), None)
                out.append((j, k, len(m.group(1)) + 2, iid)); j = k
            else: j += 1
        return out

    def _set_ask(path, ask_id, kv):
        """Set keys on ONE ask item in place (the rest of the file untouched). False when the id is not found."""
        text = open(path, encoding="utf-8").read()
        fm, body = T.split(text)
        span = next((s for s in _ask_spans(fm) if s[3] == str(ask_id)), None)
        if not span: return False
        a, b, ind, _ = span
        while b > a + 1 and not fm[b - 1].strip(): b -= 1
        for k, v in kv:
            line = " " * ind + f"{k}: {T.qv(v)}"
            n = next((n for n in range(a, b) if re.match(rf"\s*(- )?{re.escape(k)}:(\s|$)", fm[n])), None)
            if n is None: fm.insert(b, line); b += 1
            elif fm[n].lstrip().startswith("- "): fm[n] = " " * (ind - 2) + "- " + line.lstrip()
            else: fm[n] = line
        T.write_atomic(path, "---\n" + "\n".join(fm) + "\n---\n" + body)
        return True
    T.set_ask = _set_ask


def now(): return dt.datetime.now()
def stamp(): return now().strftime("%Y-%m-%dT%H:%M")


def when(v):
    for f in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try: return dt.datetime.strptime(str(v).strip(), f)
        except (ValueError, TypeError): pass
    return None


def is_open(a): return isinstance(a, dict) and str(a.get("status") or "open").lower() == "open"


def flat(s, n): return re.sub(r"\s+", " ", str(s or ""))[:n]


def norm(s): return re.sub(r"[^a-z0-9]+", " ", re.sub(r"^(updated|corrected)\b[^:]*:", "", str(s or "").lower())).strip()[:120]


def successors(all_tasks):
    """name -> successor name, from `continues:` on the newer task or `handoff: superseded by X` on the older."""
    out = {}
    # Names get reused: a `continues:` only supersedes a task that started before the successor (else an old
    # successor would close the asks of a NEW task that reused the name).
    when = {fm["name"]: str(fm.get("started") or fm.get("created") or "") for _, fm in all_tasks}
    for _, fm in all_tasks:
        c = fm.get("continues")
        if c:
            mine, theirs = str(fm.get("started") or fm.get("created") or ""), when.get(str(c), "")
            if not (mine and theirs and mine[:16] < theirs[:16]):
                out.setdefault(str(c), fm["name"])
        m = re.search(r"superseded by (\S+)", str(fm.get("handoff") or ""))
        if m: out[fm["name"]] = m.group(1).strip("\"'.,")
    return out


def task_state(fm, succ):
    """'live' | 'closed:<why>' — a closed task's asks never show."""
    st = str(fm.get("status") or "").lower()
    if st.startswith("broken"): return "closed:broken"
    if fm["name"] in succ: return f"closed:superseded by {succ[fm['name']]}"
    if st in CLOSED: return f"closed:task {st}"
    return "live"


def fresh(a):
    t = max([x for x in (when(a.get("checked")), when(a.get("asked"))) if x] or [None], key=lambda x: x or dt.datetime.min)
    return bool(t) and now() - t <= dt.timedelta(hours=FRESH_H)


def own(name, all_prefixes=False): return all_prefixes or name.startswith(PFX + "-")


def collect(all_prefixes=False):
    ts = [(p, fm) for p, fm in T.list_tasks(COSDIR) if own(fm["name"], all_prefixes)]
    return ts, successors(T.list_tasks(COSDIR))


def run_check(path, a):
    cmd = str(a.get("check") or "").strip()
    if not cmd: return None
    try:
        r = subprocess.run(["bash", "-c", cmd], cwd=COSDIR, capture_output=True, timeout=15)
        code = r.returncode
    except subprocess.TimeoutExpired: code = "timeout"
    if code == 0:
        T.set_ask(path, a["id"], [("status", "stale"), ("stale_reason", f"check passed {stamp()}: {cmd[:120]}"), ("closed", stamp())])
        return "stale"
    if code == 1:
        T.set_ask(path, a["id"], [("checked", stamp())]); return "checked"
    T.set_ask(path, a["id"], [("check_error", f"{stamp()} exit {code}")]); return f"error {code}"


def cmd_check(files):
    if not files:
        ts, succ = collect(); files = [p for p, fm in ts if task_state(fm, succ) == "live"]
    for p in files:
        try: fm, _ = T.read(p)
        except Exception as e: print(f"skip {p}: {e}", file=sys.stderr); continue
        for a in fm.get("asks") or []:
            if is_open(a) and a.get("id") and a.get("check"):
                print(f"{fm['name']}:{a['id']} {run_check(p, a)}")


def cmd_sweep(dry):
    ts, succ = collect()
    closed, orphan = 0, []
    for p, fm in ts:
        st = task_state(fm, succ)
        if st == "live": continue
        for a in fm.get("asks") or []:
            if not (is_open(a) and a.get("id")): continue
            text = f"{a.get('what')} {a.get('options') or ''}"
            if HARD.search(text) and not st.startswith("closed:superseded"):
                orphan.append(f"ORPHAN {fm['name']}:{a['id']} ({st[7:]}) {flat(a.get('what'), 140)}"); continue
            closed += 1
            if not dry: T.set_ask(p, a["id"], [("status", "stale"), ("stale_reason", f"{st[7:]} — its answer reaches no one; a live task re-files it if still needed"), ("closed", stamp())])
    print(f"sweep: {'would close' if dry else 'closed'} {closed} asks of closed/superseded tasks; {len(orphan)} orphan hard-gate asks")
    for o in orphan: print(o)
    if not dry: cmd_check([])


def rows(all_prefixes=False):
    ts, succ = collect(all_prefixes)
    out, seen = [], {}
    for p, fm in ts:
        if task_state(fm, succ) != "live": continue
        for a in fm.get("asks") or []:
            if not is_open(a): continue
            r = {"w": fm["name"], "file": p, "id": a.get("id") or "?", "cls": str(a.get("class") or "?").upper(), "what": a.get("what") or "—",
                 "asked": str(a.get("asked") or ""), "checked": str(a.get("checked") or ""), "fresh": fresh(a),
                 "check": a.get("check") or "", "evidence": a.get("evidence") or "", "dups": [],
                 "hard": bool(HARD.search(f"{a.get('what')} {a.get('options') or ''}")),
                 "blocks": not a.get("default_if_silent")}
            r["why"] = "hard gate" if r["hard"] else ("the user runs it" if r["cls"] == "TEST" else "")
            k = norm(r["what"])
            if k and k in seen: seen[k]["dups"].append(f"{r['w']}:{r['id']}"); continue
            seen[k] = r; out.append(r)
    out.sort(key=lambda r: (not r["fresh"], r["asked"]))
    return out


def cmd_list(all_prefixes, as_json):
    rs = rows(all_prefixes)
    if as_json: print(json.dumps(rs, ensure_ascii=False, indent=1)); return
    f = [r for r in rs if r["fresh"]]
    print(f"FRESH {len(f)} (checked/asked < {FRESH_H:g} h) · RE-CHECK {len(rs) - len(f)}")
    for r in rs:
        tag = "FRESH  " if r["fresh"] else "RECHECK"
        how = "check" if r["check"] else ("evidence" if r["evidence"] else "no check")
        print(f"{tag} {r['w']}:{r['id']} {r['cls']} asked {r['asked']} checked {r['checked'] or '-'} [{how}]"
              + (f" dups {','.join(r['dups'])}" if r["dups"] else "") + f"\n        {flat(r['what'], 160)}")


def queue(rs=None):
    """The ONE user queue (fresh asks only): (shown, rest). Hard gate/blocker first, then TEST, then oldest. Max
    $COS_USER_QUEUE_MAX (5) shown; the rest are named in one line, never dropped."""
    rs = [r for r in (rs if rs is not None else rows()) if r["fresh"]]
    rs.sort(key=lambda r: (0 if r["hard"] else (1 if r["blocks"] else 2), {"TEST": 0, "APPROVE": 1, "DECIDE": 2}.get(r["cls"], 3), r["asked"]))
    k = int(os.environ.get("COS_USER_QUEUE_MAX") or 5)
    return rs[:k], rs[k:]


def main(a):
    if not a or a[0] in ("-h", "--help"): print(__doc__); return 2
    c = a[0]
    if c == "queue":
        shown, rest = queue()
        if "--json" in a: print(json.dumps({"shown": shown, "rest": rest}, ensure_ascii=False, indent=1)); return 0
        print(f"USER QUEUE {len(shown)}" + (f" (+{len(rest)} more)" if rest else ""))
        for r in shown: print(f"{r['w']}:{r['id']} {r['cls']}{' · ' + r['why'] if r['why'] else ''}\n        {flat(r['what'], 160)}")
        if rest: print("more: " + ", ".join(f"{r['w']}:{r['id']}" for r in rest))
    elif c == "list": cmd_list("--all" in a, "--json" in a)
    elif c == "check": cmd_check(a[1:])
    elif c == "sweep": cmd_sweep("--dry-run" in a)
    elif c == "verify" and len(a) >= 3:
        kv = [("checked", stamp())] + ([("evidence", " ".join(a[3:]))] if len(a) > 3 else [])
        if not T.set_ask(a[1], a[2], kv): print(f"no ask {a[2]} in {a[1]}", file=sys.stderr); return 1
    elif c == "close" and len(a) >= 4:
        if not T.set_ask(a[1], a[2], [("status", "stale"), ("stale_reason", " ".join(a[3:])), ("closed", stamp())]):
            print(f"no ask {a[2]} in {a[1]}", file=sys.stderr); return 1
    else: print(__doc__); return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
