#!/usr/bin/env bash
# Headless chief sweep for a Hermes cron (--no-agent script mode: stdout is delivered).
#   hermes-sweep.sh brief   stand-up brief (08:00 / 13:00 / 18:00) — always prints
#   hermes-sweep.sh         sweep — prints only a FIRE / new blocker, else [SILENT]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../cos-env.sh"
[ -n "${COS_HERMES:-}" ] || { echo "addon hermes not configured, skipping"; exit 0; }
hb="$COS_DIR/_heartbeat"
if [ -f "$hb" ]; then
  age_h=$(( ($(date +%s) - $(stat -f %m "$hb")) / 3600 ))
  if [ "$age_h" -ge 3 ]; then echo "chief sweep stale: last heartbeat ${age_h}h ago"; fi
fi
"$HERE/../queue-run.sh" 2>/dev/null || true   # queued tasks for this machine spawn even when no chief session is alive
cd "$COS_MONOREPO"
if [ "${1:-}" = brief ]; then
  P="/agent-ops:chief-of-staff brief — headless run from Hermes. Do BRIEF mode and print ONLY the stand-up (ONE Thing, Did, To Do with goals, Blockers). No preamble."
else
  P="/agent-ops:chief-of-staff sweep — headless run from Hermes. Print ONLY a new FIRE or new blocker for you, else exactly [SILENT]."
fi
"${COS_CLAUDE_BIN:-claude}" -p "$P" \
  --model opus --max-turns 60 --dangerously-skip-permissions
