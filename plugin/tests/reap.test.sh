#!/bin/bash
# Tests for skills/chief-of-staff/scripts/reap.sh (session half) and hooks/cos-reap.sh — fake sessions TSV, fake stop.sh.
# Run: bash plugin/tests/reap.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REAP="$HERE/../skills/chief-of-staff/scripts/reap.sh"
T=$(mktemp -d -t reaptest)
trap 'for p in $(pgrep -f "$T"); do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
mkdir -p "$T/cos/tasks"
printf 'COS_DIR=%q\nCOS_MACHINE_PREFIX=a\nCOS_HOST_PREFIX=a\n' "$T/cos" > "$T/config.env"
export AGENT_OPS_CONFIG="$T/config.env" COS_REAP_SESSIONS_TSV="$T/sess.tsv" COS_REAP_STOP="$T/stop"
unset COS_WORKER COS_REAP COS_DIR COS_MACHINE_PREFIX COS_HOST_PREFIX   # a worker running the test must not leak its own
export COS_REAP_IDLE_MIN=3   # fixtures use minute-scale idles; the shipped default is 60 (checked below)
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
[ "$(grep -c 'COS_REAP_IDLE_MIN:-60' "$REAP")" -ge 2 ] && ok "default reap idle = 60 min" || bad "default reap idle = 60 min"

printf '#!/bin/bash\necho "$*" >> %q/stop.log\n[ "${STOP_RC:-0}" = 0 ] || { echo "WARN: $1 reports DONE without: teardown:" >&2; exit "$STOP_RC"; }\n' "$T" > "$T/stop"
chmod +x "$T/stop"

task() {   # task NAME STATUS [fm lines…] -- [report lines…]
  local n=$1 st=$2 f="$T/cos/tasks/$1.md"; shift 2
  { echo "---"; echo "name: $n"; echo "status: $st"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do echo "$1"; shift; done; [ $# -gt 0 ] && shift
    echo "---"; echo "charter"; echo; echo "## Reports"; for l in "$@"; do echo "- $l"; done; } > "$f"
}
reset() {
  rm -f "$T/stop.log" "$T/cos/.reap-refused" "$T/cos/.reap-unseen" "$T/cos"/.reap-pending-* "$T/cos"/tasks/*.md "$T/cos/LEADS"
  printf 'state\tname\tpid\tage_m\tidle_m\tacct\tcwd\nlive\ta-live\t1\t10\t0\t-\t/\nlive\ta-done\t2\t10\t5\t-\t/\nlive\ta-fresh\t3\t10\t1\t-\t/\nlive\ta-park\t4\t10\t9\t-\t/\nlive\ta-again\t5\t10\t9\t-\t/\nDEAD\ta-dead\t7\t10\t9\t-\t/\nlive\tb-done\t8\t10\t9\t-\t/\nlive\ta-pinged\t9\t10\t0\t-\t/\nlive\ta-lead\t10\t10\t9\t-\t/\nlive\ta-chief\t11\t10\t9\t-\t/\n' > "$T/sess.tsv"
  task a-dead running -- 'status: DONE 2026-10-21 10:00'
  task a-live running -- 'status: WORKING 2026-10-21 10:00'
  task a-done running -- 'status: STARTED 2026-10-21 09:00' 'status: DONE 2026-10-21 10:00 · refs: none'
  task a-fresh running -- "status: DONE $(date '+%Y-%m-%d %H:%M')"
  task a-pinged running -- 'status: DONE 2026-10-21 10:00'   # check-in pings keep idle 0; the report is old
  task a-park parked -- 'status: BLOCKED 2026-10-21 10:00'
  task a-again running -- 'status: DONE 2026-10-20 10:00' 'STARTED again' 'status: WORKING 2026-10-21 10:00'
  task b-done running -- 'status: DONE 2026-10-21 10:00'
  task a-lead running -- 'status: DONE 2026-10-21 10:00'
  task a-chief running -- 'status: DONE 2026-10-21 10:00'
  printf 'a · web · a-lead · the web app\n' > "$T/cos/LEADS"
  touch -t 202601010000 "$T/cos"/tasks/*.md
}

reset
out=$(bash "$REAP" --dry-run 2>&1)
[ ! -f "$T/stop.log" ] && grep -q "would run stop.sh a-done DONE" <<<"$out" && ok "dry-run names the stop, changes nothing" || bad "dry-run" "$out"

reset
out=$(bash "$REAP" 2>&1)
grep -qx "a-done DONE" "$T/stop.log" && ok "live DONE idle 5m → stop.sh DONE" || bad "live DONE → stop.sh DONE" "$out $(cat "$T/stop.log" 2>/dev/null)"
grep -qx "a-park PARKED" "$T/stop.log" && ok "live parked → stop.sh PARKED" || bad "live parked → stop.sh PARKED"
! grep -q "a-fresh" "$T/stop.log" && ok "DONE but idle 1m < 3m → waits" || bad "DONE idle 1m waits"
grep -qx "a-pinged DONE" "$T/stop.log" && ok "DONE report older than window, idle 0 (pinged) → stop.sh DONE" || bad "old DONE report closes despite pings"
! grep -q "a-again" "$T/stop.log" && ok "DONE before the last STARTED is ignored" || bad "old DONE ignored"
! grep -q "a-live\|a-dead\|b-done" "$T/stop.log" && ok "working / dead / foreign-prefix workers not stopped" || bad "no stop for working/dead/foreign" "$(cat "$T/stop.log")"
! grep -q "a-lead\|a-chief" "$T/stop.log" && ok "LEADS lead and the chief never reaped" || bad "lead/chief reaped" "$(cat "$T/stop.log")"
! grep -q -- "--force" "$T/stop.log" && ok "never --force" || bad "never --force"

reset
out=$(STOP_RC=7 bash "$REAP" --sessions-only 2>&1)
grep -q "a-done left open — stop.sh a-done DONE refused (exit 7): a-done reports DONE without: teardown:" <<<"$out" \
  && ok "refusal → one line for the chief" || bad "refusal line" "$out"
grep -q "^- reap: .*refused (exit 7)\|^reap: .*refused (exit 7)" "$T/cos/tasks/a-done.md" && ok "refusal → report line in the task" || bad "refusal report line" "$(cat "$T/cos/tasks/a-done.md")"
out=$(STOP_RC=7 bash "$REAP" --sessions-only --alert 2>&1)
[ -z "$out" ] && ok "--alert: same refusal not re-printed" || bad "--alert dedupe" "$out"

reset
: > "$T/sess.tsv"
out=$(bash "$REAP" 2>&1)
[ ! -f "$T/stop.log" ] && ok "sessions.sh empty → nothing done" || bad "empty sessions → nothing" "$out"

# report-line PARKED with task still running; a `reap:` line quoting "STARTED" must not hide DONE
reset
printf 'state\tname\tpid\tage_m\tidle_m\tacct\tcwd\nlive\ta-rpark\t1\t60\t15\t-\t/\nlive\ta-quoted\t2\t60\t15\t-\t/\nlive\ta-unpark\t3\t60\t15\t-\t/\n' > "$T/sess.tsv"
rm -f "$T/cos"/tasks/*.md
task a-rpark running 'continues: a-rpark0' -- 'status: STARTED 2026-10-21 14:31' 'status: WORKING 2026-10-21 15:30 x' 'status: PARKED 2026-10-21 15:33 x — waiting on review'
task a-quoted running -- 'status: STARTED 2026-10-21 13:59' 'status: DONE 2026-10-21 14:3x x · refs: a · teardown: 0' \
  'reap: 2026-10-21 14:36 stop.sh DONE refused (exit 7): a-quoted reports DONE without: shipped: — required since the last STARTED — left open'
task a-unpark running -- 'status: STARTED 2026-10-21 10:00' 'status: PARKED 2026-10-21 11:00' 'status: RESUMED 2026-10-21 12:00 session abc' 'status: WORKING 2026-10-21 12:05'
touch -t 202601010000 "$T/cos"/tasks/*.md
out=$(bash "$REAP" --sessions-only 2>&1)
grep -qx "a-rpark PARKED" "$T/stop.log" 2>/dev/null && ok "report-line PARKED (task still running) → stop.sh PARKED" || bad "report-line PARKED → stop" "$out $(cat "$T/stop.log" 2>/dev/null)"
grep -qx "a-quoted DONE" "$T/stop.log" 2>/dev/null && ok "a reap: line quoting \"STARTED\" does not hide the DONE above it" || bad "quoted STARTED hides DONE" "$out"
! grep -q "a-unpark" "$T/stop.log" 2>/dev/null && ok "PARKED then RESUMED/WORKING → not stopped" || bad "resumed after park stopped"

# hooks/cos-reap.sh
HOOK="$HERE/../hooks/cos-reap.sh"; export CLAUDE_PLUGIN_ROOT="$HERE/.."
printf '{"hook_event_name":"Stop"}' | COS_WORKER=a-rpark COS_REPORT_FILE="$T/cos/tasks/a-rpark.md" COS_REAP_DELAY_S=600 bash "$HOOK"
[ -f "$T/cos/.reap-pending-a-rpark" ] && ok "hook: Stop after a report-line PARKED schedules one reap" || bad "hook: PARKED line schedules"
printf '{"hook_event_name":"Stop"}' | COS_WORKER=a-unpark COS_REPORT_FILE="$T/cos/tasks/a-unpark.md" COS_REAP_DELAY_S=600 bash "$HOOK"
[ ! -f "$T/cos/.reap-pending-a-unpark" ] && ok "hook: PARKED then WORKING schedules nothing" || bad "hook: unpark schedules"
rm -f "$T/cos"/.reap-pending-*
printf '{"hook_event_name": "SessionEnd", "reason": "clear"}' | COS_WORKER=a-rpark COS_REPORT_FILE="$T/cos/tasks/a-rpark.md" COS_REAP_DELAY_S=600 bash "$HOOK"
[ ! -f "$T/cos/.reap-pending-a-rpark" ] && ok "hook: SessionEnd for /clear schedules nothing" || bad "hook: SessionEnd clear"
printf '{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}' | COS_WORKER=a-rpark COS_REPORT_FILE="$T/cos/tasks/a-rpark.md" COS_REAP_DELAY_S=600 bash "$HOOK"
[ -f "$T/cos/.reap-pending-a-rpark" ] && ok "hook: SessionEnd (exit) after PARKED schedules one reap" || bad "hook: SessionEnd exit schedules"
rm -f "$T/cos"/.reap-pending-*
for p in $(pgrep -f "$T"); do kill "$p" 2>/dev/null; done   # the 600 s delayed runs above
printf '{"hook_event_name":"Stop"}' | AGENT_OPS_CONFIG="$T/no-config" COS_WORKER=a-rpark COS_REPORT_FILE="$T/cos/tasks/a-rpark.md" COS_REAP_DELAY_S=600 bash "$HOOK"
[ ! -f "$T/cos/.reap-pending-a-rpark" ] && ok "hook: no agent-ops config → inactive" || bad "hook: inactive without config"
printf '{"hook_event_name":"Stop"}' | COS_REPORT_FILE="$T/cos/tasks/a-rpark.md" bash "$HOOK"
[ ! -f "$T/cos/.reap-pending-a-rpark" ] && ok "hook: not a worker (no COS_WORKER) → nothing" || bad "hook: non-worker no-op"
# the detached Stop-hook run's refusal reaches the chief: queued, printed once by the next full run
rm -f "$T/stop.log"
out=$(STOP_RC=7 bash "$REAP" --only a-quoted --from-hook 2>&1)
grep -q "a-quoted left open" "$T/cos/.reap-unseen" 2>/dev/null && ok "hook-run refusal queued for the chief" || bad "hook-run refusal queued" "$out"
out=$(STOP_RC=7 bash "$REAP" --alert 2>&1)
[ "$(grep -c "a-quoted left open" <<<"$out")" = 1 ] && ok "next full --alert run prints the queued refusal once" || bad "queued refusal printed once" "$out"
[ ! -f "$T/cos/.reap-unseen" ] && ok "queue cleared after printing" || bad "queue cleared"

reset
printf '{"hook_event_name":"Stop"}' | COS_WORKER=a-done COS_REPORT_FILE="$T/cos/tasks/a-done.md" COS_REAP_DELAY_S=1 bash "$HOOK"
[ -f "$T/cos/.reap-pending-a-done" ] && ok "hook: Stop after DONE schedules one reap" || bad "hook: DONE schedules"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -qx "a-done DONE" "$T/stop.log" 2>/dev/null && break; sleep 0.5; done
grep -qx "a-done DONE" "$T/stop.log" 2>/dev/null && ok "hook: delayed reap ran stop.sh a-done DONE" || bad "hook: delayed reap ran" "$(cat "$T/stop.log" 2>/dev/null)"
! grep -q "a-park" "$T/stop.log" 2>/dev/null && ok "hook: delayed reap is --only that worker" || bad "hook: delayed reap scope"

echo; echo "PASS $PASS  FAIL $FAIL"; [ "$FAIL" = 0 ]
