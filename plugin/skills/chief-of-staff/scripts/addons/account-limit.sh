#!/usr/bin/env bash
# Claude account load balancing for workers. State: $COS_ACCOUNTS (default $COS_DIR/accounts.md),
# a small table `| id | status | limited_until | note |`. The default Keychain login's id is $COS_KEYCHAIN_ACCOUNT
# (config.env; legacy id `a`) — others = Keychain items cos-claude-account-<id> (account-add.sh). An entry past
# its limited_until counts as ok automatically.
#   account-limit.sh <id> [<reset>]   mark <id> limited. <reset> = HH:MM (today, or tomorrow if already past)
#                                     or "YYYY-MM-DD HH:MM"; omitted → now + 5 h. Take it from the worker's
#                                     usage-limit message ("… resets 3pm" → 15:00).
#   account-limit.sh --clear <id>     mark <id> ok (also registers a new id)
#   account-limit.sh --show           each account: effective status, until, live sessions, Keychain present
#   account-limit.sh --pick           print the id `auto` resolves to: the ok account with the fewest live
#                                     sessions (sessions.sh live names → LEDGER account column; sessions not in
#                                     LEDGER, and old rows without an account, or LEDGER account `a`/`-`, count
#                                     as $COS_KEYCHAIN_ACCOUNT). `a` never wins auto. Tie → $COS_DEFAULT_ACCOUNT.
#                                     All limited → exit 4, stderr names the soonest reset.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../cos-env.sh"
if [ "$COS_OS" != mac ]; then   # multi-account tokens live in the macOS Keychain
  if [ "${1:-}" = --pick ]; then echo "addon accounts: macOS only, skipping" >&2; echo a; else echo "addon accounts: macOS only, skipping"; fi
  exit 0
fi
[ -n "${COS_ACCOUNTS:-}${COS_DEFAULT_ACCOUNT:-}" ] || { echo "addon accounts not configured, skipping"; exit 0; }
ACC="${COS_ACCOUNTS:-$COS_DIR/accounts.md}"
MODE=set ID= RESET=
case "${1:-}" in
  --clear) MODE=clear; ID="${2:-}";; --show) MODE=show;; --pick) MODE=pick;;
  ""|-h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  -*) echo "unknown arg $1" >&2; exit 2;;
  *) ID="$1"; RESET="${2:-}";;
esac
if [ "$MODE" = set ] || [ "$MODE" = clear ]; then
  [[ "$ID" =~ ^[a-z][a-z0-9]{0,5}$ ]] || { echo "bad account id '$ID' (a, b, c…)" >&2; exit 2; }
fi
# Keychain presence (attributes only — never -w) for every id we might report on.
KC=$(security dump-keychain 2>/dev/null | sed -nE 's/^.*"svce"<blob>="cos-claude-account-([a-z][a-z0-9]*)"$/\1/p' | sort -u | paste -sd, - || true)
SESS=""; [ "$MODE" = set ] || [ "$MODE" = clear ] || SESS=$("$HERE/../sessions.sh" --tsv 2>/dev/null || true)
cos_python - "$ACC" "$MODE" "$ID" "$RESET" "$KC" "$COS_DIR/LEDGER.md" "$SESS" "${COS_KEYCHAIN_ACCOUNT:-a}" "${COS_DEFAULT_ACCOUNT:-}" <<'PY'
import sys, os, re, datetime as dt
acc, mode, aid, reset, kc, ledger, sess, keyacct, defacct = sys.argv[1:]
now = dt.datetime.now().replace(second=0, microsecond=0)
FMT = "%Y-%m-%d %H:%M"
HEAD = ["# Claude accounts — worker load balancing", "",
        "Written by account-limit.sh / account-add.sh (chief-of-staff). The default Keychain login's id is set by",
        "COS_KEYCHAIN_ACCOUNT (config.env; legacy id `a`). Other ids = Keychain items `cos-claude-account-<id>`.",
        "A `limited` row past `limited_until` counts as ok. Tokens never live here.", "",
        "| id | status | limited_until | note |", "|---|---|---|---|"]
rows = {}
if os.path.exists(acc):
    for l in open(acc, encoding="utf-8"):
        c = [x.strip() for x in l.strip().strip("|").split("|")]
        if l.lstrip().startswith("|") and len(c) >= 3 and re.fullmatch(r"[a-z][a-z0-9]{0,5}", c[0]) and c[0] != "id":
            rows[c[0]] = {"status": c[1] or "ok", "until": c[2], "note": c[3] if len(c) > 3 else ""}
rows.setdefault(keyacct, {"status": "ok", "until": "", "note": "default Keychain login"})
def until(r):
    try: return dt.datetime.strptime(r["until"], FMT)
    except (ValueError, TypeError): return None
def eff(r):
    if r["status"] != "limited": return "ok"
    u = until(r)
    return "limited" if (u is None or u > now) else "ok"
def save():
    L = HEAD + [f"| {k} | {v['status']} | {v['until']} | {v['note'].replace('|', '/')} |" for k, v in sorted(rows.items())]
    tmp = acc + ".tmp"; open(tmp, "w", encoding="utf-8").write("\n".join(L) + "\n"); os.replace(tmp, acc)
if mode in ("set", "clear"):
    r = rows.setdefault(aid, {"status": "ok", "until": "", "note": ""})
    if mode == "clear":
        r["status"], r["until"] = "ok", ""
        r["note"] = "default Keychain login" if aid in ("a", keyacct) else f"cleared {now:%m-%d %H:%M}"
        save(); print(f"account {aid}: ok"); sys.exit(0)
    if not reset: u = now + dt.timedelta(hours=5)
    elif re.fullmatch(r"\d{1,2}:\d\d", reset):
        h, m = map(int, reset.split(":"))
        if h > 23 or m > 59: sys.exit(f"bad reset time {reset}")
        u = now.replace(hour=h, minute=m)
        if u <= now: u += dt.timedelta(days=1)
    else:
        try: u = dt.datetime.strptime(reset, FMT)
        except ValueError: sys.exit(f"bad reset '{reset}' — HH:MM or 'YYYY-MM-DD HH:MM'")
    r["status"], r["until"] = "limited", u.strftime(FMT)
    r["note"] = f"marked {now:%m-%d %H:%M}"
    save(); print(f"account {aid}: limited until {r['until']} — spawn successors with --account auto"); sys.exit(0)
# ---- show / pick ----
kcs = set(filter(None, kc.split(",")))
for k in kcs: rows.setdefault(k, {"status": "ok", "until": "", "note": "in Keychain, not yet in accounts.md"})
acct = {}
if os.path.exists(ledger):
    for l in open(ledger, encoding="utf-8", errors="ignore"):
        c = [x.strip() for x in l.strip().strip("|").split("|")]
        if len(c) >= 7 and re.match(r"\d{4}-\d\d-\d\d", c[0]):
            v = c[7] if len(c) >= 8 and re.fullmatch(r"[a-z][a-z0-9]{0,5}", c[7]) else "a"
            acct[c[1]] = keyacct if v == "a" else v   # LEDGER `a`/`-`/missing → the default-login id

for _d in [os.path.join(os.path.dirname(ledger), "tasks")]:   # task files carry the account
    for _f in (sorted(os.listdir(_d)) if os.path.isdir(_d) else []):
        if not _f.endswith(".md") or _f.startswith("."): continue
        _fm = {}
        _L = open(os.path.join(_d, _f), encoding="utf-8", errors="ignore").read().split("\n")
        if _L and _L[0] == "---":
            for _l in _L[1:]:
                if _l == "---": break
                _m = re.match(r"(name|account):\s*(.*)", _l)
                if _m: _fm[_m.group(1)] = _m.group(2).strip().strip("\"'")
        if _fm.get("account"): acct[_fm.get("name") or _f[:-3]] = keyacct if _fm["account"] == "a" else _fm["account"]
live = {k: 0 for k in rows}
for l in sess.splitlines()[1:]:
    p = l.split("\t")   # sessions.sh --tsv: full name
    if len(p) >= 5 and p[0] == "live":
        k = acct.get(p[1], keyacct); live[k] = live.get(k, 0) + 1
def usable(k): return k == keyacct or k in kcs   # `a` itself left the auto pool
if mode == "show":
    print(f"{'id':4} {'status':8} {'until':17} {'live':>4}  keychain  note")
    for k, r in sorted(rows.items()):
        print(f"{k:4} {eff(r):8} {(r['until'] if eff(r) == 'limited' else '-'):17} {live.get(k, 0):>4}  "
              f"{'default' if k == keyacct else ('yes' if k in kcs else 'MISSING'):9} {r['note']}")
    sys.exit(0)
ok = [k for k, r in rows.items() if eff(r) == "ok" and usable(k)]
if not ok:
    lim = sorted((until(r) or now, k) for k, r in rows.items() if usable(k))
    soon = f"{lim[0][1]} at {lim[0][0]:%Y-%m-%d %H:%M}" if lim else "?"
    print(f"all accounts limited — soonest reset: {soon}. Queue the work (LEDGER QUEUED) or clear one: account-limit.sh --clear <id>", file=sys.stderr)
    sys.exit(4)
pick = min(ok, key=lambda k: (live.get(k, 0), k != defacct, k))
print("auto → " + pick + " (live: " + " ".join(f"{k}={live.get(k, 0)}" for k in sorted(rows) if usable(k)) +
      "; limited: " + (", ".join(k for k, r in sorted(rows.items()) if eff(r) == "limited") or "none") + ")", file=sys.stderr)
print(pick)
PY
