#!/usr/bin/env bash
# waste-watch — read the subagent ledger and flag subagents that ran too long.
# For the SWEEP: prints, per worker (session), every subagent over the threshold in the
# last N hours, so a 🟡 row can be raised for a worker whose subagents keep over-running
# (usually a self-watch/sleep burning wall-clock).
#
#   waste-watch.sh [--mins M] [--hours H] [--file PATH]
#     --mins   M   flag subagents at/over M minutes (default 15)
#     --hours  H   look back H hours (default 24)
#     --file   P   ledger path (default $COS_DIR/subagent-ledger.tsv)
#
# Exit 0 always. Prints nothing when nothing is over the threshold (clean SWEEP).
set -euo pipefail

MINS=15 HOURS=24
LEDGER="${SUBAGENT_LEDGER_FILE:-${COS_DIR:-$HOME/agent-ops/state}/subagent-ledger.tsv}"
while [ $# -gt 0 ]; do
  case "$1" in
    --mins)  MINS="$2"; shift 2;;
    --hours) HOURS="$2"; shift 2;;
    --file)  LEDGER="$2"; shift 2;;
    *) echo "waste-watch: unknown arg $1" >&2; exit 0;;
  esac
done

[ -f "$LEDGER" ] || { echo "waste-watch: no ledger yet ($LEDGER)"; exit 0; }

THRESH_S=$(( MINS * 60 ))
# Cutoff as an ISO string — our ts (YYYY-MM-DDTHH:MM:SS) sorts lexically, so no epoch
# math in awk (macOS BWK awk has no mktime).
CUTOFF_ISO=$(date -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%S 2>/dev/null \
  || date -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)

awk -F'\t' -v thr="$THRESH_S" -v cutoff="$CUTOFF_ISO" -v mins="$MINS" -v hours="$HOURS" '
  NR==1 && $1=="ts" { next }                       # header
  {
    ts=$1; sess=$2; desc=$3; model=$4; dur=$5; calls=$6
    if (ts < cutoff) next
    if (dur+0 < thr) next
    n[sess]++
    worst[sess] = (dur+0 > worst[sess]+0) ? dur : worst[sess]
    line[sess] = line[sess] sprintf("    %5.1f min  %-6s  %3s calls  %s\n", dur/60, model, calls, desc)
  }
  END {
    if (length(n)==0) exit 0
    printf "⚠️  Subagents over %d min in the last %d h (self-watch/sleep waste?):\n", mins, hours
    for (sess in n)
      printf "  %s — %d over-long (worst %.1f min):\n%s", sess, n[sess], worst[sess]/60, line[sess]
    print "  → raise a 🟡 row per worker; look for sleep/poll loops in those subagents."
  }
' "$LEDGER"
exit 0
