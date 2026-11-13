#!/bin/bash
# cos-reap — Stop + SessionEnd hook for chief-spawned workers (env COS_WORKER); any other session exits at the first
# line. No stdout, always exit 0, never blocks. Inactive unless the agent-ops config exists.
#   SessionEnd with reason clear or resume: nothing (the session goes on). Any other SessionEnd (exit, logout, pane
#     closed): the same check as Stop, so a worker that ends right after DONE/PARKED is still reaped.
#   Stop: when the task file's latest report status is DONE or PARKED, or the task is parked, schedule ONE detached
#     `reap.sh --only NAME` in COS_REAP_DELAY_S (240) s, which runs `stop.sh NAME DONE|PARKED` with every gate
#     (never --force): sessions are closed when they are done. The awk below is the cheap pre-check; reap.sh
#     decides. A pane killed without a Stop (terminal quit, SIGHUP) is caught by a periodic `reap.sh` run.
# Kill switch COS_REAP=0.
[ -n "${COS_WORKER:-}" ] && [ "${COS_REAP:-1}" != 0 ] || exit 0
case "$COS_WORKER" in *[!a-z0-9-]*) exit 0;; esac
[ -f "${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}" ] || exit 0
IN=$(cat 2>/dev/null || true)
if printf '%s' "$IN" | grep -Eq '"hook_event_name"[[:space:]]*:[[:space:]]*"SessionEnd"'; then
  printf '%s' "$IN" | grep -Eq '"reason"[[:space:]]*:[[:space:]]*"(clear|resume)"' && exit 0
fi
S="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/skills/chief-of-staff/scripts/reap.sh"
[ -f "$S" ] || exit 0
F="${COS_REPORT_FILE:-}"
[ -f "$F" ] || exit 0
# last report status DONE or PARKED, or task `status: parked` (a report-line PARKED counts; any later status line —
# WORKING, RESUMED, STARTED — clears it; a `reap:` line quoting "STARTED" does not)
awk '/status:[[:space:]]*\**[[:space:]]*(DONE|PARKED)([^A-Za-z]|$)/ {d=1; next}
     /status:[[:space:]]*\**[[:space:]]*(STARTED|RESUMED|WORKING|BLOCKED|FAILED|STOPPED)/ {d=0}
     /^status:[[:space:]]*parked/ {p=1} END {exit !(d || p)}' "$F" 2>/dev/null || exit 0
bash "$S" --schedule "$COS_WORKER" >/dev/null 2>&1
exit 0
