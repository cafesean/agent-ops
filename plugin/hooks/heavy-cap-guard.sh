#!/bin/bash
# heavy-cap-guard — PreToolUse(Bash) hook. Bash keyword pre-filter, python only when the command could be heavy.
# Spec: heavy-cap-guard.py header. Inactive (exit 0, no output) unless the agent-ops config exists. Fails open.
INPUT=$(cat)
[ "${COS_ALLOW_HEAVY_CAP:-}" = 1 ] && exit 0
[ -f "${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}" ] || exit 0
case "$INPUT" in
  *tsc*|*tsgo*|*typecheck*|*type-check*|*check-types*|*build*|*test*|*vitest*|*jest*) ;;
  *) exit 0 ;;
esac
. "$(dirname "$0")/../skills/chief-of-staff/scripts/lib/cos-os.sh" 2>/dev/null || exit 0
printf '%s' "$INPUT" | cos_python "$(dirname "$0")/heavy-cap-guard.py" || true
exit 0
