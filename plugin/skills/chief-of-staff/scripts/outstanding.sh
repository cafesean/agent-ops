#!/usr/bin/env bash
# Build the owner's ONE outstanding list from every place work lives, into $COS_OUTSTANDING (markdown note).
# Keeps every machine's `<!-- cos:next:<prefix> -->` plan block (written by that machine's next.sh) in place.
# Core sources: open boxes in state-dir notes, the chief's workers. Optional (each skipped with one line when
# not configured): Jira (COS_JIRA_BASE + COS_JIRA_JQL), Apple Reminders (COS_REMINDERS=1 + remindctl), Hermes flags
# (COS_HERMES=1), where-it-is (shipped.yaml registry). Read-only on every source.
#   outstanding.sh           write the note, print the counts line
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"
TMP=$(mktemp -d)
echo '{}' > "$TMP/jira.json"; echo '[]' > "$TMP/overdue.json"; echo '[]' > "$TMP/week.json"; : > "$TMP/hermes.txt"; : > "$TMP/where.md"
JQL="${COS_JIRA_JQL:-}"
if [ -n "${COS_JIRA_BASE:-}" ] && [ -n "$JQL" ]; then
  curl -s -m 20 -H "Authorization: Bearer ${JIRA_API_TOKEN:-}" \
    "$COS_JIRA_BASE/rest/api/2/search?maxResults=100&fields=summary,status,updated&jql=$(cos_python -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$JQL")" > "$TMP/jira.json" || echo '{}' > "$TMP/jira.json"
else cos_skip jira "COS_JIRA_BASE/COS_JIRA_JQL not set"; fi
if [ -n "${COS_REMINDERS:-}" ] && command -v remindctl >/dev/null 2>&1; then
  remindctl show overdue --json > "$TMP/overdue.json" 2>/dev/null || echo '[]' > "$TMP/overdue.json"
  remindctl show week --json > "$TMP/week.json" 2>/dev/null || echo '[]' > "$TMP/week.json"
fi
if [ -n "${COS_HERMES:-}" ]; then "$HERE/addons/hermes-jobs.sh" --flags > "$TMP/hermes.txt" 2>/dev/null || true
else cos_skip hermes "COS_HERMES not set"; fi
"$HERE/collect.sh" > "$TMP/workers.txt" 2>/dev/null || true
if [ -n "${COS_SHIPPED:-}" ] || [ -f "$COS_DIR/shipped.yaml" ]; then
  "$HERE/addons/where-it-is.sh" > "$TMP/where.md" 2>/dev/null || echo "where-it-is.sh failed — run it by hand" > "$TMP/where.md"
fi
cos_python - "$TMP" "$COS_OUTSTANDING" "${COS_JIRA_BASE:-}" "$(dirname "$COS_OUTSTANDING")" "$COS_DIR" "${COS_VAULT:-}" "${COS_OUTSTANDING_SKIP:-}" <<'PY'
import json, os, sys, glob, re, datetime as dt
tmp, out, jbase, cosroot, cosdir, vaultroot, skipenv = sys.argv[1:]
# Vault root: $COS_VAULT, else the nearest parent of $COS_DIR holding .obsidian/
if not vaultroot or not os.path.isdir(vaultroot):
    d = os.path.abspath(cosdir)
    while d != os.path.dirname(d) and not os.path.isdir(os.path.join(d, ".obsidian")): d = os.path.dirname(d)
    vaultroot = d if os.path.isdir(os.path.join(d, ".obsidian")) else os.path.dirname(os.path.dirname(cosdir))
state_link = os.path.relpath(os.path.join(cosdir, "STATE"), vaultroot)
next_link = os.path.relpath(os.path.join(cosdir, "NEXT"), vaultroot)  # next.sh's plan daemon output
now = dt.datetime.now()
# Each machine's next.sh owns a `<!-- cos:next:<prefix> -->` block in this note — carry them over verbatim.
prev = open(out, encoding="utf-8").read() if os.path.exists(out) else ""
next_blocks = [mm.group(0) for mm in re.finditer(r"<!-- cos:next:([a-z]) -->.*?<!-- /cos:next:\1 -->", prev, re.S)]
def load(n, d):
    try: return json.load(open(f"{tmp}/{n}"))
    except Exception: return d
L = []
# Jira
j = load("jira.json", {})
# Which cards show is decided by COS_JIRA_JQL alone; rows group by status name (no hardcoded workflow columns).
jira = sorted(j.get("issues", []), key=lambda i: (i["fields"]["status"]["name"], i["key"]))
# Reminders
od = [r for r in load("overdue.json", []) if not r.get("isCompleted")]
wk = [r for r in load("week.json", []) if not r.get("isCompleted") and r.get("id") not in {x.get("id") for x in od}]
# Vault unchecked boxes (skip templates/archive/briefs history)
vault = []
skipdirs = [d.strip() for d in skipenv.split(":") if d.strip()]   # COS_OUTSTANDING_SKIP: extra folders to skip
for f in glob.glob(f"{cosroot}/**/*.md", recursive=True):
    rel = os.path.relpath(f, cosroot)
    if re.match(r"(Templates|_archive|Sessions|tasks|briefs|launch|inbox|charters)/", rel) or rel == os.path.basename(out): continue
    if skipdirs and any(rel == d or rel.startswith(d.rstrip("/") + "/") for d in skipdirs): continue
    age = (now - dt.datetime.fromtimestamp(os.path.getmtime(f))).days
    for n, line in enumerate(open(f, errors="ignore"), 1):
        m = re.match(r"\s*[-*] \[ \] (.+)", line)
        if m: vault.append((rel, n, m.group(1).strip()[:100], age))
hermes = [l.strip() for l in open(f"{tmp}/hermes.txt") if l.strip()]
workers = [l.rstrip() for l in open(f"{tmp}/workers.txt")][1:]
active = [w for w in workers if not re.search(r"\s(DONE|STOPPED|FAILED)\s", w)]
# ONE Thing from newest brief
one = "—"
briefs = sorted(glob.glob(f"{cosdir}/briefs/*.md"))
if briefs:
    for line in open(briefs[-1]):
        m1 = re.match(r"^[^A-Za-z]*ONE Thing:\**\s*(.+)", line)  # tolerates "**🎯 ONE Thing: x** — why"
        if m1: one = m1.group(1).replace("**", "").strip(); break
on_you = len(jira) + len(od) + len([h for h in hermes if h.startswith("FAIL")])
L += ["---", f"updated: {now:%Y-%m-%d %H:%M}", "generated_by: agent-ops outstanding.sh — do not edit, it is overwritten every sweep", "---", "",
      f"# Outstanding — {now:%a %d %b %H:%M}", "",
      *(next_blocks or [f"![[{next_link}]]"]), "",
      *(["## Where it is — live git over shipped.yaml (`where-it-is.sh`)", ""] + [l.rstrip("\n") for l in open(f"{tmp}/where.md", errors="ignore")] + [""] if os.path.getsize(f"{tmp}/where.md") else []),
      f"**ONE Thing:** {one}", "",
      f"**On you: {on_you}** · Jira {len(jira)} · overdue reminders {len(od)} · due this week {len(wk)} · vault open boxes {len(vault)} · Hermes flags {len(hermes)} · workers running {len(active)}", ""]
if jbase: L += ["## Jira — waiting on you", ""]
if jira:
    L += ["| card | status | summary | updated |", "|---|---|---|---|"]
    for i in jira:
        f = i["fields"]; s = f["status"]["name"]
        L.append(f"| [{i['key']}]({jbase}/browse/{i['key']}) | {s} | {f['summary'][:70].replace('|','/')} | {f['updated'][:10]} |")
elif jbase: L.append("none")
def rem(rows, title):
    L.extend(["", f"## Reminders — {title}", ""])
    if not rows: L.append("none"); return
    L.extend(["| list | reminder | due |", "|---|---|---|"])
    for r in sorted(rows, key=lambda r: (r.get("listName",""), r.get("dueDate") or "")):
        L.append(f"| {r.get('listName','')} | {r.get('title','')[:70].replace('|','/')} | {(r.get('dueDate') or '')[:10]} |")
if od or wk: rem(od, "overdue"); rem(wk, "due in 7 days")
tracked = f"{cosdir}/tracked.md"
if os.path.exists(tracked):   # legacy file; tracked items normally live under their goal in GOALS.md
    L += ["", "## Tracked items (`tracked.md`)", ""]
    L += [l.rstrip() for l in open(tracked)]
L += ["", "## Notes — open boxes", ""]
if vault:
    L += ["| note | item | note age (days) |", "|---|---|---|"]
    for rel, n, t, age in sorted(vault, key=lambda v: v[3]):
        L.append(f"| [[{rel[:-3]}]] | {t.replace('|','/')} | {age}{' stale?' if age > 60 else ''} |")
else: L.append("none")
if hermes: L += ["", "## Hermes jobs — problems", ""] + [f"- {h}" for h in hermes]
L += ["", "## Chief's workers", ""] + ([f"- `{w}`" for w in active] or ["none running"])
open(out, "w").write("\n".join(L) + "\n")
print(f"on you {on_you} | jira {len(jira)} | overdue {len(od)} | week {len(wk)} | vault {len(vault)} | hermes {len(hermes)} | workers {len(active)} → {out}")
PY
rm -rf "$TMP"
