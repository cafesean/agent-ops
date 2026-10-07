#!/usr/bin/env bash
# Decide where new work can run. Prints one verdict line + the numbers behind it.
#   LOCAL      — room here
#   LOCAL_LIGHT— only read-only / small work here (sonnet research, no tsc/vitest/next build)
#   OFFLOAD    — queue new sessions (or send them to the remote runner add-on)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/cos-env.sh"

note=""
case "$COS_OS" in
  mac)
    ncpu=$(sysctl -n hw.ncpu)
    load1=$(sysctl -n vm.loadavg | awk '{print $2}')
    free_pct=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/{gsub("%","",$2);print $2}' || true);;
  windows)   # Git Bash / MSYS: no load average, no reliable memory figure, ps lacks -o → approximate
    ncpu="${NUMBER_OF_PROCESSORS:-$(nproc 2>/dev/null || echo 1)}"
    load1=0; free_pct=""
    note="note: windows (Git Bash) — no load/memory check, verdict approximate; use WSL2 for a real one";;
  *)
    ncpu=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    free_pct=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} /MemFree/{f=$2} END{if (!a) a=f; if (t) printf "%d", a*100/t}' /proc/meminfo 2>/dev/null || true);;
esac
free_pct="${free_pct%%.*}"
sessions=0
if [ "$COS_OS" = windows ]; then   # registry pids are Windows pids: msys `kill -0` cannot see them
  sessions=$("$DIR/sessions.sh" --tsv 2>/dev/null | awk -F'\t' '$1=="live"' | wc -l | tr -d ' ') || sessions=0
else
  sessions=$(ls "$HOME/.claude/sessions/"*.json 2>/dev/null | while read -r f; do
    pid=$(basename "$f" .json); kill -0 "$pid" 2>/dev/null && echo "$pid"; done | wc -l | tr -d ' ') || true   # empty dir: ls fails under pipefail
fi
# heavy = build/test workers with a live parent; orphans (ppid 1) are reported separately — they hold RAM, not CPU
PAT='tsc --noEmit|vitest|jest-worker|next build'
heavy=0; orphans=0; orphan_mb=0
if [ "$COS_OS" != windows ] && command -v pgrep >/dev/null 2>&1; then
  for p in $(pgrep -f "$PAT" 2>/dev/null || true); do
    read -r ppid rss < <(ps -o ppid=,rss= -p "$p" 2>/dev/null || echo "0 0")
    if [ "$ppid" = 1 ]; then orphans=$((orphans+1)); orphan_mb=$((orphan_mb + rss/1024)); else heavy=$((heavy+1)); fi
  done
elif [ "$COS_OS" != windows ]; then note="note: pgrep not found — heavy build/test jobs not counted"; fi
per_cpu=$(awk -v l="$load1" -v n="$ncpu" 'BEGIN{printf "%.2f", l/n}')

verdict=LOCAL; why=()
awk -v p="$per_cpu" -v m="$COS_MAX_LOAD_PER_CPU" 'BEGIN{exit !(p>m)}' && { verdict=OFFLOAD; why+=("load/cpu $per_cpu > $COS_MAX_LOAD_PER_CPU"); }
[ "${free_pct:-100}" -lt "$COS_MIN_FREE_MEM_PCT" ] && { verdict=OFFLOAD; why+=("free mem ${free_pct}% < ${COS_MIN_FREE_MEM_PCT}%"); }
[ "$sessions" -ge "$COS_MAX_LOCAL_SESSIONS" ] && { verdict=OFFLOAD; why+=("$sessions live sessions >= $COS_MAX_LOCAL_SESSIONS"); }
if [ "$verdict" = LOCAL ] && { [ "$heavy" -gt 0 ] || [ "${free_pct:-100}" -lt $((COS_MIN_FREE_MEM_PCT + 10)) ]; }; then
  verdict=LOCAL_LIGHT; why+=("heavy jobs=$heavy, free mem ${free_pct}%")
fi
echo "$verdict${why:+ — ${why[*]}}"
echo "cpu=$ncpu load1=$load1 load/cpu=$per_cpu free_mem=${free_pct:-?}% sessions=$sessions heavy=$heavy"
[ -z "$note" ] || echo "$note"
# Orphans (opt-in, COS_KILL_ORPHANS=1): they ignore SIGTERM, so TERM then KILL. Otherwise only reported.
if [ "$orphans" -gt 0 ] && [ "${COS_KILL_ORPHANS:-0}" != 1 ]; then
  echo "orphans: $orphans build/test workers with ppid 1 (~${orphan_mb}MB) — set COS_KILL_ORPHANS=1 to auto-kill"
elif [ "$orphans" -gt 0 ]; then
  ids=$(for p in $(pgrep -f "$PAT"); do [ "$(ps -o ppid= -p "$p" | tr -d ' ')" = 1 ] && echo "$p"; done)
  echo "$ids" | xargs kill 2>/dev/null || true; sleep 2
  echo "$ids" | xargs kill -9 2>/dev/null || true
  echo "orphans: killed $orphans build/test workers with ppid 1 (~${orphan_mb}MB freed)"
fi
exit 0
