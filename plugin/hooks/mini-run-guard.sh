#!/bin/bash
# mini-run-guard — PreToolUse(Bash) hook. Heavy commands (tsc, next build, pnpm build, full test suites)
# run on the remote runner via `mini-run <cmd>`, not on this machine. Fires for subagents too.
# Fast path: a keyword pre-filter in bash; python only when the command could be heavy.
# Escape hatches: COS_ALLOW_LOCAL_HEAVY=1 (env or in the command) · `# local-ok: <reason>` in the command.
# Active ONLY when the remote runner add-on is configured (MINI_RUN_HOST / COS_REMOTE_HOST / COS_INVENTORY in
# the agent-ops config, or COS_MINI_RUN_BIN in env) AND a scope root is known (COS_HEAVY_GUARD_ROOT, else
# COS_MONOREPO). Otherwise: exit 0 silently, no output.
INPUT=$(cat)
[ "${COS_ALLOW_LOCAL_HEAVY:-}" = 1 ] && exit 0
if [ -z "${COS_HEAVY_GUARD_ROOT:-}" ] || [ -z "${COS_MINI_RUN_BIN:-}" ]; then
  CFG="${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}"
  # shellcheck disable=SC1090
  [ -f "$CFG" ] && eval "$(tr -d '\r' < "$CFG")" >/dev/null 2>&1   # CRLF-tolerant
fi
[ -n "${MINI_RUN_HOST:-}${COS_REMOTE_HOST:-}${COS_INVENTORY:-}${COS_MINI_RUN_BIN:-}" ] || exit 0
COS_HEAVY_GUARD_ROOT="${COS_HEAVY_GUARD_ROOT:-${COS_MONOREPO:-}}"
case "$COS_HEAVY_GUARD_ROOT" in ""|"<"*) exit 0;; esac
export COS_HEAVY_GUARD_ROOT
case "$INPUT" in
  *tsc*|*typecheck*|*type-check*|*check-types*|*build*|*test*|*vitest*) ;;
  *) exit 0 ;;
esac
# COS_PYTHON fallbacks (python3 → python → py -3); no python at all → stay silent, never block the user
. "$(dirname "$0")/../skills/chief-of-staff/scripts/lib/cos-os.sh" 2>/dev/null || exit 0
printf '%s' "$INPUT" | cos_python "$(dirname "$0")/mini-run-guard.py"
