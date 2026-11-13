#!/bin/bash
# cos-py — shared entry for the chief-of-staff python hooks: `bash cos-py.sh <hook>.py`.
# Inactive (exit 0, no output, stdin ignored) unless the agent-ops config exists ($AGENT_OPS_CONFIG, else
# ~/.claude/agent-ops/config.env — checked by name only, never read here). Runs the hook with cos_python
# (python3 → python → py -3); no python at all → exit 0. Hooks find their libs relative to this plugin
# (${CLAUDE_PLUGIN_ROOT}/skills/chief-of-staff/scripts). Never blocks on its own error.
[ -f "${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}" ] || exit 0
H="$(cd "$(dirname "$0")" && pwd)"
case "$1" in */*|"") exit 0;; esac
[ -f "$H/$1" ] || exit 0
. "$H/../skills/chief-of-staff/scripts/lib/cos-os.sh" 2>/dev/null || exit 0
cos_python "$H/$1"
exit $?
