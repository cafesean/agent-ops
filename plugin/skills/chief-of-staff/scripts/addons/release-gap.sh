#!/usr/bin/env bash
# What is on develop but not on prod, per product — from CONTENT, never commit ancestry.
# Hold-out cuts revert work on main while its commits stay in main's history, so origin/main..origin/develop
# counts held work as shipped. Per repo: fetch origin, `git diff origin/<prod> origin/develop` = held files;
# each file traced to the develop commits whose change is not in prod's copy (lib/prodcontent.py), grouped
# by change (commit) with author + date. A differing file is NOT every commit that touched it.
# Read-only on every app repo (git fetch, log, diff, ls-tree; apply --check into a temp index).
#   release-gap.sh                    markdown table, every product
#   release-gap.sh --product <name>   one product
#   release-gap.sh --json             JSON instead of the table
#   release-gap.sh --no-fetch         skip the fetch (uses last-fetched refs; stamped "stale")
# Repo map: $COS_RELEASE_REPOS = "product:repo,repo;product:repo,..." — repo is a dir under
# $COS_MONOREPO or an absolute path; `repo@branch` forces the prod branch (default: detect
# main → master → production → prod). Missing dirs are skipped with a note.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../cos-env.sh"
[ -n "${COS_RELEASE_REPOS:-}" ] || { echo "addon release-gap not configured, skipping"; exit 0; }

PRODUCT="" JSON=0 FETCH=1 MAXLIST=5
while [ $# -gt 0 ]; do
  case "$1" in
    --product) PRODUCT="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    --no-fetch) FETCH=0; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "release-gap: unknown arg $1" >&2; exit 2 ;;
  esac
done

MAP="$COS_RELEASE_REPOS"
ROOT="${COS_MONOREPO:-}"
G() { command git "$@"; }   # never the rtk proxy — it fabricates git output
US=$'\x1f'
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

IFS=';' read -ra GROUPS_ <<< "$MAP"
for grp in "${GROUPS_[@]}"; do
  prod_name="${grp%%:*}"; repos="${grp#*:}"
  [ -n "$PRODUCT" ] && [ "$prod_name" != "$PRODUCT" ] && continue
  IFS=',' read -ra RS <<< "$repos"
  for spec in "${RS[@]}"; do
    [ -z "$spec" ] && continue
    repo="${spec%%@*}"; forced=""; [ "$spec" != "$repo" ] && forced="${spec#*@}"
    case "$repo" in /*) path="$repo" ;; *) path="$ROOT/$repo" ;; esac
    name="$(basename "$repo")"
    if ! G -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
      printf '%s\n' "$prod_name${US}$name${US}-${US}skip: no repo at $path${US}${US}" >> "$TMP"; continue
    fi
    note=""
    if [ "$FETCH" = 1 ]; then
      G -C "$path" fetch -q origin 2>/dev/null || note="fetch FAILED (refs may be stale); "
    else
      note="no-fetch (stale refs); "
    fi
    if [ -n "$forced" ]; then prodb="$forced"
    else
      prodb=""
      for b in main master production prod; do
        G -C "$path" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null && { prodb="$b"; break; }
      done
    fi
    if ! G -C "$path" rev-parse -q --verify refs/remotes/origin/develop >/dev/null; then
      printf '%s\n' "$prod_name${US}$name${US}-${US}${note}no origin/develop${US}$prodb${US}" >> "$TMP"; continue
    fi
    if [ -z "$prodb" ] || ! G -C "$path" rev-parse -q --verify "refs/remotes/origin/$prodb" >/dev/null; then
      printf '%s\n' "$prod_name${US}$name${US}-${US}${note}no prod branch (main/master/production/prod)${US}$prodb${US}" >> "$TMP"; continue
    fi
    [ "$prodb" != "main" ] && note="${note}prod branch = $prodb; "
    n=$(G -C "$path" rev-list --no-merges --count "origin/$prodb..origin/develop")
    behind=$(G -C "$path" rev-list --no-merges --count "origin/develop..origin/$prodb")
    [ "$behind" != 0 ] && note="${note}$prodb has $behind non-merge commit(s) not on develop (hotfix?); "
    printf '%s\n' "$prod_name${US}$name${US}OK${US}$note${US}$prodb${US}$path${US}$n" >> "$TMP"
  done
done

if [ ! -s "$TMP" ]; then
  echo "release-gap: no repos matched${PRODUCT:+ product '$PRODUCT'} (map: $MAP)" >&2; exit 1
fi

cos_python - "$TMP" "$JSON" "$MAXLIST" "$HERE/../lib" <<'PY'
import sys, json, datetime as dt
path, as_json, maxlist = sys.argv[1], sys.argv[2] == "1", int(sys.argv[3])
sys.path.insert(0, sys.argv[4]); import prodcontent as P
now = dt.datetime.now(); hm = now.strftime("%H:%M")
rows = []
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if not line: continue
    p = line.split("\x1f"); p += [""] * (7 - len(p))
    product, repo, state, note, prodb, rpath, anc = p[:7]
    row = {"product": product, "repo": repo, "prod_branch": prodb or None, "held_files": None,
           "changes": [], "files": [], "ancestry_ahead": int(anc) if anc.isdigit() else None,
           "note": None, "checked": now.isoformat(timespec="seconds")}
    notes = [note.strip().rstrip(";")] if note.strip() else []
    if state == "OK":
        r = P.Repo(rpath, f"origin/{prodb}", "origin/develop")
        try:
            files = r.held_files(); row["held_files"] = len(files)
            ch, hows = {}, {}
            for f in files:
                miss, how = r.missing_for_file(f); hows[how] = hows.get(how, 0) + 1
                row["files"].append({"path": f, "how": how, "commits": [c["short"] for c in miss]})
                for c in miss:
                    e = ch.setdefault(c["sha"], {k: c[k] for k in ("short", "author", "date", "subj")} | {"files": 0})
                    e["files"] += 1
            row["changes"] = sorted(ch.values(), key=lambda e: (-e["files"], e["date"]))
            if hows.get("own-edits") or hows.get("merge-made"):
                notes.append(f"{hows.get('own-edits', 0) + hows.get('merge-made', 0)} file(s) where prod has its own edits — confirm by hand")
            if files and row["ancestry_ahead"] == 0:
                notes.append("git log says 0 commits ahead — held work is hidden by a hold-out revert")
        finally:
            r.close()
    elif state not in ("", "OK", "-"):
        notes.append(state)
    row["note"] = "; ".join(n for n in notes if n) or None
    rows.append(row)
if as_json:
    print(json.dumps({"checked": now.isoformat(timespec="seconds"), "method": "content", "rows": rows}, indent=2)); sys.exit()
esc = lambda s: str(s).replace("|", "\\|")
print(f"Release gap — develop content not on prod · checked {now.strftime('%Y-%m-%d')} {hm}\n")
print("| Product | Repo | held on develop | held changes (commit · who · date · files) | checked |")
print("|---|---|---|---|---|")
for r in rows:
    if r["held_files"] is None: held = "—"
    elif r["held_files"] == 0: held = "0 ✅"
    else: held = f"**{r['held_files']} files** · {len(r['changes'])} changes"
    if r["held_files"] and r["prod_branch"] and r["prod_branch"] != "main": held += f" (vs {r['prod_branch']})"
    cells = [esc(f"{c['short']} {c['subj'][:70]} · {c['author']} · {c['date']} · {c['files']}f") for c in r["changes"][:maxlist]]
    if len(r["changes"]) > maxlist: cells.append(f"…{len(r['changes']) - maxlist} more (--json)")
    top = "<br>".join(cells)
    if r["note"]: top = (top + "<br>" if top else "") + f"_{esc(r['note'])}_"
    print(f"| {r['product']} | {r['repo']} | {held} | {top or '—'} | {hm} |")
tot = sum(r["held_files"] or 0 for r in rows)
need = [f"{r['product']}/{r['repo']}" for r in rows if r["held_files"]]
print(f"\n{tot} files held across {len(need)} repo(s)" + (f": {', '.join(need)}" if need else "") + ".")
print("Content check: git diff origin/<prod> origin/develop, each file traced to the commits missing from prod's copy. "
      "Commit counts (git log/cherry) are NOT used — hold-out reverts keep held commits in main's history. "
      "Git content only — not proof of what a host is running.")
PY
