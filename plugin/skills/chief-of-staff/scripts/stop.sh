#!/usr/bin/env bash
# Stop a worker the chief spawned: kill its claude pid, drop its registry file, close its pane/window
# (task `where:` — `tmux <session>:<name>`, or cmux `ws<N>/surface:<M>`; never the chief's own) and mark the
# task closed. Only for workers the chief spawned — never the owner's own sessions.
#   stop.sh NAME [STATUS] [--force] [--dry-run]     STATUS defaults to STOPPED
#   --dry-run: run every gate and mark the task closed, but kill no pid and close no pane/window.
# Session-log gate (any STATUS): the task's report since its last STARTED needs a line containing "session:" or
#   "sessions/" (the worker wrote its session log) — else refuse (exit 4) unless --force.
# Open-ask gate: a task with an open ask to the owner is waiting on them, not done — refuse (exit 5) unless the
#   task is `status: parked` (worker wrote its handoff) or --force.
# Ownership gate: a machine stops only workers with its own prefix (cos-env.sh cos_own) — exit 6.
# DONE gate: STATUS=DONE refuses (exit 7) unless the report since the last STARTED has
#   - always: a `session:` line (session log) and a `teardown:` line (worktrees removed/kept, servers stopped)
#   - COS_REQUIRE_REFS=1: a `refs:` line (reference docs updated, or "none")
#   - ship-tracking add-on on (COS_SHIPPED set) and code moved (a commit hash or `where: pushed|dev|prod`): a `shipped:` line
#   - Jira add-on on (COS_JIRA_BASE set): a `jira:` tag
# Close: sets the task `status: done|failed|stopped|parked` + a `closed:` stamp, so no live task outlives its worker.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"
FORCE=0; DRY=0; ARGS=()
for a in "$@"; do case "$a" in --force) FORCE=1;; --dry-run) DRY=1;; *) ARGS+=("$a");; esac; done
NAME="${ARGS[0]:-}"; [ -n "$NAME" ] || { echo "usage: stop.sh NAME [STATUS] [--force] [--dry-run]" >&2; exit 2; }
STATUS="${ARGS[1]:-STOPPED}"
TPY="$HERE/lib/tasks.py"
TFILE="$COS_DIR/tasks/$NAME.md"; [ -f "$TFILE" ] || TFILE=
[ -n "$TFILE" ] || grep -q "| $NAME |" "$COS_DIR/LEDGER.md" 2>/dev/null || { echo "refuse: $NAME is not a chief-spawned worker (no tasks/$NAME.md, not in LEDGER)" >&2; exit 3; }
where_of() { if [ -n "$TFILE" ]; then cos_python "$TPY" get "$TFILE" where; else grep "| $NAME |" "$COS_DIR/LEDGER.md" | tail -1 | awk -F'|' '{print $4}' | xargs; fi; }
cos_own "$NAME" || { echo "refuse: $NAME is not this machine's worker (prefix ${COS_PREFIX}-, host ${COS_HOST_PREFIX}) — stop it on its own machine" >&2
  [ "$FORCE" = 1 ] || exit 6; echo "--force: stopping a foreign-prefix worker" >&2; }
INBOX="${TFILE:-$COS_DIR/inbox/$NAME.md}"
MFILE="$COS_DIR/missions/$NAME.yaml"
if [ -n "$TFILE" ]; then   # task file: open asks live in its frontmatter
  OPEN=$(cos_python -c 'import sys; sys.path.insert(0, sys.argv[1]); import tasks; fm, _ = tasks.read(sys.argv[2])
print(0 if str(fm.get("status")) == "parked" else sum(1 for a in fm.get("asks") or [] if isinstance(a, dict) and str(a.get("status") or "open").lower() == "open"))' "$HERE/lib" "$TFILE")
  if [ "${OPEN:-0}" -gt 0 ]; then
    echo "WARN: $NAME has $OPEN open ask(s) to the owner in $TFILE — it is waiting on them, not done. Park it (handoff + status: parked) instead" >&2
    [ "$FORCE" = 1 ] || { echo "refuse: re-run with --force to stop $NAME with an open ask" >&2; exit 5; }
  fi
  MFILE=/nonexistent
fi
if [ "$STATUS" = DONE ]; then
  MISSING=$(cos_python - "$INBOX" "${COS_JIRA_BASE:-}" "${COS_REQUIRE_REFS:-0}" "${COS_SHIPPED:-}" <<'PY'
import re, sys, os
p, jira_on, refs_on, ship_on = sys.argv[1], bool(sys.argv[2]), sys.argv[3] == "1", bool(sys.argv[4])
lines = open(p, encoding="utf-8", errors="ignore").read().split("\n") if os.path.exists(p) else []
start = max([i for i, l in enumerate(lines) if "STARTED" in l] or [0])
blk = "\n".join(lines[start:])
need = []
if not re.search(r"session:|sessions/", blk): need.append("session:")
if not re.search(r"\bteardown:", blk): need.append("teardown:")
if refs_on and not re.search(r"(?m)^\s*[-*]?\s*refs:", blk): need.append("refs:")
if jira_on and not re.search(r"\bjira:\s*\S", blk): need.append("jira:")
moved = re.search(r"where:\s*(pushed|dev|prod)", blk) or re.search(r"\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b", blk)
if ship_on and moved and not re.search(r"(?m)^\s*[-*]?\s*shipped:", blk): need.append("shipped:(code moved)")
print(" ".join(need))
PY
)
  if [ -n "$MISSING" ]; then
    echo "WARN: $NAME reports DONE without: $MISSING — required in its task report since the last STARTED" >&2
    [ "$FORCE" = 1 ] || { echo "refuse: ask $NAME to add them, or re-run with --force" >&2; exit 7; }
  fi
fi
if [ -f "$MFILE" ]; then
  OPEN=$(cos_python - "$MFILE" <<'PY'
import re, sys
top, parked, items = None, False, []
for raw in open(sys.argv[1], encoding="utf-8", errors="ignore"):
    line = raw.split(" #")[0].rstrip()
    m = re.match(r"([A-Za-z_][\w-]*):\s*(.*)", line)
    if m:
        top = m.group(1)
        if top == "status" and m.group(2).strip().strip("\"'") == "parked": parked = True
        continue
    if top != "asks": continue
    b = line.strip()
    if b.startswith("- "): items.append({}); b = b[2:].strip()
    k = re.match(r"([A-Za-z_][\w-]*):\s*(.*)", b)
    if k and items: items[-1][k.group(1)] = k.group(2).strip().strip("\"'")
n = sum(1 for i in items if i.get("status", "open").lower() == "open")
print(0 if parked else n)
PY
)
  if [ "${OPEN:-0}" -gt 0 ]; then
    echo "WARN: $NAME has $OPEN open ask(s) to the owner in $MFILE — it is waiting on them, not done. Park it (handoff + mission status: parked) instead" >&2
    [ "$FORCE" = 1 ] || { echo "refuse: re-run with --force to stop $NAME with an open ask" >&2; exit 5; }
  fi
fi
if ! { [ -f "$INBOX" ] && awk '/STARTED/ {seen=0; next} /session:|sessions\// {seen=1} END {exit !seen}' "$INBOX"; }; then
  echo "WARN: $NAME inbox has no session log (no \"session:\" or \"sessions/\" line since its last STARTED) — ask it to run /agent-ops:session-update first" >&2
  [ "$FORCE" = 1 ] || { echo "refuse: re-run with --force to stop $NAME without a session log" >&2; exit 4; }
  echo "--force: stopping $NAME without a session log" >&2
fi
for f in "$HOME"/.claude/sessions/*.json; do
  [ -e "$f" ] || continue
  [ "$DRY" = 0 ] || { cos_python -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get('name')==sys.argv[2] else 1)" "$f" "$NAME" 2>/dev/null && echo "DRY-RUN: would kill pid $(basename "$f" .json)"; continue; }
  if cos_python -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get('name')==sys.argv[2] else 1)" "$f" "$NAME" 2>/dev/null; then
    pid=$(basename "$f" .json); kill -9 "$pid" 2>/dev/null || { [ "$COS_OS" = windows ] && taskkill //PID "$pid" //F >/dev/null 2>&1; } || true; rm -f "$f" "$HOME/.claude/sessions/$pid".*.key; echo "killed pid $pid"
  fi
done
# Remote worker (where = remote:…): kill its tmux window on the remote runner (claude gets SIGHUP).
RTS="${COS_REMOTE_TMUX_SESSION:-agent-ops}"
if [ "$DRY" = 1 ]; then echo "DRY-RUN: would close $NAME's pane/window ($(where_of))"
elif where_of | grep -q 'remote:'; then
  if RHOST=$(cos_remote_host) && [ -n "${COS_REMOTE_USER:-}" ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$COS_REMOTE_USER@$RHOST" \
      "$(printf '%q' "${COS_REMOTE_TMUX_BIN:-tmux}")${COS_REMOTE_TMUX_SOCKET:+ -S $(printf '%q' "$COS_REMOTE_TMUX_SOCKET")} kill-window -t $RTS:$NAME" \
      && echo "closed remote tmux window $RTS:$NAME" || echo "WARN: no remote tmux window $RTS:$NAME (already gone?)" >&2
  else cos_skip "remote close" "remote runner add-on not configured"; fi
elif where_of | grep -qE '^wt '; then
  echo "note: Windows Terminal tab \"$NAME\" stays open (wt.exe cannot close tabs) — close it by hand"
elif where_of | grep -qE '^tmux '; then
  tw=$(where_of | sed -E 's/^tmux //')
  command -v tmux >/dev/null 2>&1 && cos_tmux kill-window -t "$tw" 2>/dev/null && echo "closed tmux window $tw" || echo "WARN: no tmux window $tw (already gone?)" >&2
fi
CM="${COS_CMUX_BIN:-cmux}"   # COS_CMUX_BIN: tests point it at a fake
if [ "$DRY" = 0 ] && [ "$COS_LAUNCHER" = cmux ] && command -v "$CM" >/dev/null 2>&1; then
  where=$(where_of)
  if [[ "$where" =~ ws([0-9]+)/(surface:[0-9]+) ]]; then
    ws="workspace:${BASH_REMATCH[1]}"; surf="${BASH_REMATCH[2]}"
    if "$CM" close-surface --workspace "$ws" --surface "$surf" >/dev/null 2>&1; then
      echo "closed $surf in $ws"
      # Every pane close re-equalizes that workspace (cmux has no pane hook).
      . "$HERE/addons/lib/cmux-equalize.sh" && cos_equalize "$ws"
    fi
  else
    # legacy worker spawned as its own workspace: close it only if its title is exactly NAME and it is not the chief's
    ws=$("$CM" tree --all 2>/dev/null | awk -v t="\"$NAME\"" '$0 ~ / workspace workspace:[0-9]+ / {for(i=1;i<=NF;i++) if ($i ~ /^workspace:[0-9]+$/ && $(i+1)==t) {print $i; exit}}')
    if [ -n "$ws" ] && [ "$NAME" != chief ] && [ "$ws" != "${COS_CMUX_WORKSPACE:-}" ]; then
      "$CM" close-workspace --workspace "$ws" >/dev/null 2>&1 && echo "closed $ws"
    fi
  fi
fi
if [ -n "$TFILE" ]; then
  TST=stopped; [ "$STATUS" != DONE ] || TST=done; [ "$STATUS" != FAILED ] || TST=failed; [ "$STATUS" != PARKED ] || TST=parked
  cos_python "$TPY" set "$TFILE" status "$TST" closed "$(date '+%Y-%m-%d %H:%M') stop.sh $STATUS"
  cos_python "$TPY" report "$TFILE" "closed: $(date '+%Y-%m-%d %H:%M') stop.sh $STATUS"
  echo "task: $NAME → status: $TST"
fi
grep -q "| $NAME |" "$COS_DIR/LEDGER.md" 2>/dev/null && cos_python - "$COS_DIR/LEDGER.md" "$NAME" "$STATUS" <<'PY'
import sys,re
p,n,st=sys.argv[1:]
lines=open(p).read().split("\n")
for i in range(len(lines)-1,-1,-1):
    if f"| {n} |" in lines[i]:
        cells=lines[i].split("|"); cells[7 if len(cells) > 8 else -2]=f" {st} "; lines[i]="|".join(cells); break   # status = 7th cell; 8th = account
open(p,"w").write("\n".join(lines))
PY
[ -n "$TFILE" ] || echo "ledger: $NAME → $STATUS"
if [ -f "$MFILE" ]; then
  cos_python - "$MFILE" "$STATUS" "$(date '+%Y-%m-%d %H:%M')" <<'PY'
import re, sys
p, st, stamp = sys.argv[1:]
L = open(p, encoding="utf-8").read().split("\n")
cur = next((re.sub(r"\s+#.*", "", l.split(":", 1)[1]).strip().strip("\"'") for l in L if re.match(r"status:", l)), "active")
new = cur if cur in ("done", "parked", "stopped") else ("done" if st == "DONE" else "stopped")
L = [f"status: {new}            # active | done | parked | stopped" if re.match(r"status:", l) else l for l in L if not l.startswith("closed:")]
j = next((i for i, l in enumerate(L) if l.startswith("status:")), len(L) - 1)
L.insert(j + 1, f'closed: "{stamp} stop.sh {st}"')
open(p, "w", encoding="utf-8").write("\n".join(L))
print(f"mission: {p.rsplit('/', 1)[-1]} → status: {new}")
PY
fi
