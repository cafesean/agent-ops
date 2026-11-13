#!/usr/bin/env bash
# Where is every shipped item — local / pushed / dev / prod — from LIVE git over the item registry.
# Registry: $COS_SHIPPED (default $COS_DIR/shipped.yaml). One entry per work item:
#   items: [{id, title, jira, worker, date, note?, repos: [{repo, path?, branch, commits: [hash…]}]}]
#   commits = the WORK commits (feature branch / develop merge) — never the main-merge commit (it is not on develop).
# Per commit: Local = object exists locally · Pushed = on an origin/* branch (`branch -r --contains`)
#   · Dev = in origin/develop (ancestry; not contained → same subject = "≈"; a revert on develop = note)
#   · Prod = CONTENT: every file the commit touches has its change in origin/<main|master|…>'s copy
#     (lib/prodcontent.py). Never ancestry: hold-out cuts revert work on main while the commits stay in
#     main's history, so "is commit X on main" reports held work as shipped. "≈" = file changed since — confirm.
# Item cell = the WEAKEST of its commits (✅ > ≈ > ✗). No commits = "?" (hash unknown).
# Read-only on every repo (git fetch, log/branch/diff/ls-tree, apply --check into a temp index). Git only — not what a host runs.
#   where-it-is.sh                 markdown table, gaps first
#   where-it-is.sh --json          JSON instead
#   where-it-is.sh --no-fetch      skip the fetch (stamped "stale refs")
#   where-it-is.sh --item <id>     one item
#   where-it-is.sh --file <yaml>   another registry
# Repo path: entry `path:`, else `repo` if absolute, else $COS_REPO_PATHS ("name=/abs,name2=/abs"),
# else $COS_MONOREPO/<repo>.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../cos-env.sh"
[ -n "${COS_SHIPPED:-}" ] || [ -f "$COS_DIR/shipped.yaml" ] || { echo "addon where-it-is not configured, skipping"; exit 0; }

FILE="${COS_SHIPPED:-$COS_DIR/shipped.yaml}" JSON=0 FETCH=1 ITEM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --no-fetch) FETCH=0; shift ;;
    --item) ITEM="${2:-}"; shift 2 ;;
    --file) FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "where-it-is: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -f "$FILE" ] || { echo "where-it-is: no registry at $FILE" >&2; exit 1; }

cos_python - "$FILE" "$JSON" "$FETCH" "$ITEM" "${COS_MONOREPO:-}" "${COS_REPO_PATHS:-}" "$COS_DIR" "$HERE/../lib" <<'PY'
import sys, os, re, json, subprocess, datetime as dt
sys.path.insert(0, sys.argv[8]); import prodcontent as PC
try:
    import yaml
except ImportError:
    sys.exit("where-it-is: python3 needs PyYAML (pip3 install pyyaml)")
path, as_json, fetch, only, monorepo, aliases = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1", sys.argv[4], sys.argv[5], sys.argv[6]
alias = dict(a.split("=", 1) for a in aliases.split(",") if "=" in a)
items = (yaml.safe_load(open(path)) or {}).get("items") or []
if only: items = [i for i in items if i.get("id") == only]
now = dt.datetime.now(); hm = now.strftime("%H:%M")

def git(repo, *a):
    r = subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True)  # real git, never the rtk proxy
    return r.returncode, r.stdout.strip()

def resolve(e):
    p = e.get("path") or e.get("repo", "")
    if not os.path.isabs(p): p = alias.get(p) or os.path.join(monorepo, p)
    return p

repos = {}   # path -> {ok, note, dev, prod}
def repo_info(p):
    if p in repos: return repos[p]
    info = {"ok": False, "note": "", "dev": None, "prod": None}
    if git(p, "rev-parse", "--git-dir")[0] != 0:
        info["note"] = f"no repo at {p}"; repos[p] = info; return info
    info["ok"] = True
    if fetch:
        if git(p, "fetch", "-q", "origin")[0] != 0: info["note"] = "fetch FAILED (stale refs)"
    else: info["note"] = "no-fetch (stale refs)"
    if git(p, "rev-parse", "-q", "--verify", "refs/remotes/origin/develop")[0] == 0: info["dev"] = "origin/develop"
    for b in ("main", "master", "production", "prod"):
        if git(p, "rev-parse", "-q", "--verify", f"refs/remotes/origin/{b}")[0] == 0: info["prod"] = f"origin/{b}"; break
    info["pc"] = PC.Repo(p, info["prod"], info["dev"]) if info["prod"] else None
    repos[p] = info; return info

def on_prod(p, sha, info):
    """Prod by CONTENT: ✅ every touched file has the change · ✗ held · ≈ changed since — confirm · n/a no prod branch."""
    if not info["pc"]: return "n/a", None, []
    sym, files = info["pc"].commit_on_prod(sha)
    held = [f for f, s_, _ in files if s_ == "✗"]
    more = " …" if len(held) > 3 else ""
    note, br = None, info["prod"].split("/", 1)[1]
    if held and git(p, "merge-base", "--is-ancestor", sha, info["prod"])[0] == 0:
        note = f"HELD: in {br} history but content not there ({', '.join(held[:3])}{more})"
    elif held:
        note = f"content missing on {br}: {', '.join(held[:3])}{more}"
    return sym, note, files

def on_branch(p, sha, subj, when, br):
    """✅ contained · ≈ same subject after the commit (squash/cherry-pick) · ✗ · n/a no such branch."""
    if not br: return "n/a", None
    if git(p, "merge-base", "--is-ancestor", sha, br)[0] == 0: sym = "✅"
    else:
        sym = "✗"
        if len(subj) >= 12:
            rc, out = git(p, "log", br, f"--since={when}", "--format=%h", "-F", f"--grep={subj}", "-n", "1")
            if rc == 0 and out: sym = "≈"
    rc, out = git(p, "log", br, "--format=%h", "-F", f"--grep=This reverts commit {sha[:7]}", "-n", "1")
    return sym, (f"reverted on {br.split('/',1)[1]} {out}" if out else None)

RANK = {"✅": 3, "≈": 2, "✗": 1}
def weakest(cells):
    """cells = [(sym, reponame)]; n/a ignored; returns cell text naming the repos that are weakest when mixed."""
    real = [(s, r) for s, r in cells if s in RANK]
    if not real: return "n/a" if cells else "?"
    lo = min(RANK[s] for s, _ in real); sym = [k for k, v in RANK.items() if v == lo][0]
    bad = sorted({r for s, r in real if RANK[s] == lo})
    many = len({r for _, r in real}) > 1
    return sym + (" " + ",".join(bad) if many and sym != "✅" else "")

rows = []
for it in items:
    cols = {"mac": [], "pushed": [], "dev": [], "prod": []}; notes = []; detail = []
    rl = it.get("repos") or []
    if isinstance(rl, dict):   # map form `repos: {<repo>: {branch, commits}}` → list form
        rl = [{"repo": k, **(v if isinstance(v, dict) else {})} for k, v in rl.items()]
    for e in rl:
        if not isinstance(e, dict):   # `repos: [<repo>]` — a bare name, no commits to check
            notes.append(f"{e}: no commits listed in shipped.yaml"); continue
        p = resolve(e); name = os.path.basename(e.get("repo", p).rstrip("/")); info = repo_info(p)
        if not info["ok"]:
            notes.append(f"{name}: {info['note']}"); continue
        for h in e.get("commits") or []:
            h = str(h)
            rc, sha = git(p, "rev-parse", "-q", "--verify", f"{h}^{{commit}}")
            if rc != 0:
                cols["mac"].append(("✗", name)); cols["pushed"].append(("✗", name))
                cols["dev"].append(("✗" if info["dev"] else "n/a", name)); cols["prod"].append(("✗", name))
                detail.append({"repo": name, "commit": h, "found": False}); continue
            _, meta = git(p, "log", "-1", "--format=%s%x1f%cI", sha)
            subj, when = (meta.split("\x1f") + [""])[:2]
            rc, rb = git(p, "branch", "-r", "--contains", sha, "--list", "origin/*")
            pushed = "✅" if rb.strip() else "✗"
            dsym, dnote = on_branch(p, sha, subj, when, info["dev"])
            psym, pnote, pfiles = on_prod(p, sha, info)
            if pushed == "✗" and "≈" in (dsym, psym): pushed = "≈"
            cols["mac"].append(("✅", name)); cols["pushed"].append((pushed, name))
            cols["dev"].append((dsym, name)); cols["prod"].append((psym, name))
            for n in (dnote, pnote):
                if n and f"{name} {h}: {n}" not in notes: notes.append(f"{name} {h}: {n}")
            detail.append({"repo": name, "commit": h, "found": True, "subject": subj, "pushed": pushed, "dev": dsym, "prod": psym,
                           "prod_files": [{"path": f, "state": s_, "why": w} for f, s_, w in pfiles]})
    c = {k: weakest(v) for k, v in cols.items()}
    if it.get("note"): notes.insert(0, str(it["note"]))
    first = lambda s: s.split(" ")[0]
    if c["mac"] == "?": gap, order = "hash unknown", 4
    elif first(c["mac"]) == "✗": gap, order = "hash not found locally", 3
    elif first(c["pushed"]) == "✗": gap, order = "unpushed", 3
    elif first(c["dev"]) == "✗": gap, order = "pushed, not on dev", 1
    elif first(c["prod"]) == "✗": gap, order = "on dev, not prod", 2
    elif "≈" in (first(c["dev"]), first(c["prod"])): gap, order = "≈ by subject — confirm", 5
    else: gap, order = "on prod", 6
    if any("reverted" in n for n in notes): gap += " · REVERTED"
    if any("HELD:" in n for n in notes): gap += " · HELD on main"
    rows.append({"id": it.get("id"), "title": it.get("title") or it.get("id"), "jira": it.get("jira") or "none",
                 "date": str(it.get("date") or ""), **c, "gap": gap, "order": order, "notes": notes, "commits": detail})
rows.sort(key=lambda r: (r["order"], r["date"]))
if as_json:
    print(json.dumps({"checked": now.isoformat(timespec="seconds"), "fetched": fetch, "rows": rows}, indent=2, ensure_ascii=False)); sys.exit()
esc = lambda s: str(s).replace("|", "\\|")
print(f"Where it is — {len(rows)} items from live git · checked {now:%Y-%m-%d} {hm}{'' if fetch else ' (NO fetch — stale refs)'}\n")
print(f"| Item | Jira | Local | Pushed | Dev | Prod | Gap | checked {hm} |")
print("|---|---|---|---|---|---|---|---|")
for r in rows:
    n = ("<br>_" + esc("; ".join(r["notes"]))[:220] + "_") if r["notes"] else ""
    print(f"| {esc(r['title'])}{n} | {r['jira']} | {r['mac']} | {r['pushed']} | {r['dev']} | {r['prod']} | {r['gap']} | {hm} |")
from collections import Counter
cnt = Counter(r["gap"].split(" · ")[0] for r in rows)
print("\n" + " · ".join(f"{k}: {v}" for k, v in sorted(cnt.items(), key=lambda kv: min(r["order"] for r in rows if r["gap"].startswith(kv[0])))))
rn = sorted({f"{os.path.basename(p)}: {i['note']}" for p, i in repos.items() if i["ok"] and i["note"]})
if rn and fetch: print("Repo warnings: " + "; ".join(rn))
print("Dev = in origin/develop (ancestry). Prod = CONTENT of origin/main: each file the commit touches carries its change "
      "(never commit ancestry — hold-out reverts keep held commits in main's history). No live build marker checked. "
      "✅ there · ≈ dev: same subject / prod: file changed since — confirm · ✗ not there · n/a no such branch · ? no hash in shipped.yaml. "
      "Mixed repos name the weakest.")
for i in repos.values():
    if i.get("pc"): i["pc"].close()
# Tasks: 🔨 = running now; ⚠ = a done task whose `shipped:` report names an item missing from the registry.
if not only:
    sys.path.insert(0, sys.argv[8]); import tasks as T
    ids = {str(i.get("id")) for i in (yaml.safe_load(open(path)) or {}).get("items") or []}
    run, miss = [], []
    for tp, fm in T.list_tasks(sys.argv[7]):
        st = str(fm.get("status"))
        if st in ("running", "claimed"): run.append(f"{fm.get('name')} [{fm.get('parent_goal') or '?'}] {str(fm.get('task_goal') or '')[:70]}")
        if st == "done":
            for sid in re.findall(r"(?m)^\s*[-*]?\s*shipped:\s*`?([\w.-]+)", T.reports(open(tp, encoding="utf-8", errors="ignore").read())):
                if sid != "none" and sid not in ids: miss.append(f"{fm.get('name')} → {sid}")
    if run: print("\n🔨 Building now (tasks running): " + " · ".join(run))
    if miss: print("⚠ Done tasks naming an item not in shipped.yaml: " + " · ".join(miss))
PY
