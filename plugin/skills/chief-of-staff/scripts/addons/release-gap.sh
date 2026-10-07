#!/usr/bin/env bash
# What is on develop but not on prod, per product — from LIVE git, never memory.
# Per repo: fetch origin, then count + list origin/<prod>..origin/develop.
# Read-only on every app repo (git fetch + git log only).
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
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
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
    n=$(G -C "$path" rev-list --count "origin/$prodb..origin/develop")
    nm=$(G -C "$path" rev-list --no-merges --count "origin/$prodb..origin/develop")
    [ "$nm" != "$n" ] && note="${note}$nm non-merge; "
    behind=$(G -C "$path" rev-list --no-merges --count "origin/develop..origin/$prodb")
    [ "$behind" != 0 ] && note="${note}$prodb has $behind non-merge commit(s) not on develop (hotfix?); "
    commits=$(G -C "$path" log --no-merges --format='%h %s' -n "$MAXLIST" "origin/$prodb..origin/develop" | tr '\n' '\036')
    printf '%s\n' "$prod_name${US}$name${US}$n${US}$note${US}$prodb${US}$commits" >> "$TMP"
  done
done

if [ ! -s "$TMP" ]; then
  echo "release-gap: no repos matched${PRODUCT:+ product '$PRODUCT'} (map: $MAP)" >&2; exit 1
fi

cos_python - "$TMP" "$JSON" "$MAXLIST" <<'PY'
import sys, json, datetime as dt
path, as_json, maxlist = sys.argv[1], sys.argv[2] == "1", int(sys.argv[3])
now = dt.datetime.now()
hm = now.strftime("%H:%M")
rows = []
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if not line: continue
    p = line.split("\x1f")
    p += [""] * (6 - len(p))
    product, repo, n, note, prodb, commits = p[:6]
    rows.append({
        "product": product, "repo": repo,
        "ahead": int(n) if n.isdigit() else None,
        "prod_branch": prodb or None,
        "note": note.strip().rstrip(";") or None,
        "commits": [c for c in commits.split("\x1e") if c],
        "checked": now.isoformat(timespec="seconds"),
    })
if as_json:
    print(json.dumps({"checked": now.isoformat(timespec="seconds"), "rows": rows}, indent=2)); sys.exit()
esc = lambda s: s.replace("|", "\\|")
print(f"Release gap — develop not on prod · checked {now.strftime('%Y-%m-%d')} {hm}\n")
print("| Product | Repo | develop ahead of main | top commits | checked |")
print("|---|---|---|---|---|")
for r in rows:
    if r["ahead"] is None:
        ahead = "—"
    else:
        ahead = f"**{r['ahead']}**" if r["ahead"] else "0 ✅"
        if r["prod_branch"] and r["prod_branch"] != "main": ahead += f" (vs {r['prod_branch']})"
    cells = [esc(c) for c in r["commits"]]
    shown = len(r["commits"])
    if r["ahead"] and r["ahead"] > shown and shown >= maxlist: cells.append("…more")
    top = "<br>".join(cells) or ""
    if r["note"]: top = (top + "<br>" if top else "") + f"_{esc(r['note'])}_"
    print(f"| {r['product']} | {r['repo']} | {ahead} | {top or '—'} | {hm} |")
tot = sum(r["ahead"] or 0 for r in rows)
need = [f"{r['product']}/{r['repo']}" for r in rows if r["ahead"]]
print(f"\n{tot} commits across {len(need)} repo(s) waiting for prod" + (f": {', '.join(need)}" if need else "") + ".")
print("Count includes merge commits; the list skips them. Git refs only — not proof of what a host is running.")
PY
