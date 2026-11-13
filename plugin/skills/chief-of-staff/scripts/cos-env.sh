#!/usr/bin/env bash
# Source me. Loads the agent-ops local config (never in git) and fills core defaults.
COS_CONFIG="${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}"
. "$(dirname "${BASH_SOURCE[0]}")/lib/cos-os.sh"   # cos_source_config, cos_path…
if [ ! -f "$COS_CONFIG" ]; then
  echo "agent-ops: no config at $COS_CONFIG — run /agent-ops:init" >&2
  return 1 2>/dev/null || exit 1
fi
set -a; cos_source_config "$COS_CONFIG"; set +a   # CRLF-tolerant; every key exported so python helpers and hooks see it
# (COS_OS / COS_WSL / COS_PYTHON set in the config win over the detection above)

# Windows paths in config (C:\x) → POSIX (/c/x on Git Bash, /mnt/c/x on WSL). Lists stay colon-separated.
for _v in COS_DIR COS_USER_DIR COS_OUTSTANDING COS_VAULT COS_MONOREPO COS_INVENTORY; do
  eval "_x=\${$_v:-}"; [ -z "$_x" ] || eval "$_v=\$(cos_path \"\$_x\")"
done
for _v in COS_LAUNCH_DIRS; do
  eval "_x=\${$_v:-}"; [ -z "$_x" ] || eval "$_v=\$(cos_path_list \"\$_x\")"
done
unset _v _x

# Core defaults (every add-on var stays empty unless the config sets it)
COS_DIR="${COS_DIR:-$HOME/agent-ops/state}"
COS_OUTSTANDING="${COS_OUTSTANDING:-$COS_DIR/Outstanding.md}"
# User layer: the user's own rules.md, bin/ scripts and README, outside any plugin (survives plugin updates).
COS_USER_DIR="${COS_USER_DIR:-$COS_DIR/user}"
if [ -z "${COS_LAUNCHER:-}" ]; then   # tmux if installed, else Windows Terminal on Windows/WSL, else print
  if command -v tmux >/dev/null 2>&1; then COS_LAUNCHER=tmux
  elif cos_wt_bin >/dev/null 2>&1; then COS_LAUNCHER=wt
  else COS_LAUNCHER=print; fi
fi
COS_MACHINE_PREFIX="${COS_MACHINE_PREFIX:-a}"
COS_MAX_LOCAL_SESSIONS="${COS_MAX_LOCAL_SESSIONS:-6}"
COS_MIN_FREE_MEM_PCT="${COS_MIN_FREE_MEM_PCT:-20}"
COS_MAX_LOAD_PER_CPU="${COS_MAX_LOAD_PER_CPU:-0.85}"
export COS_CONFIG COS_DIR COS_USER_DIR COS_OUTSTANDING COS_LAUNCHER COS_MACHINE_PREFIX COS_OS COS_WSL COS_PYTHON

mkdir -p "$COS_DIR/tasks" "$COS_DIR/briefs"

# Per-machine ownership: each machine writes only the tasks whose name starts with its own prefix
# (COS_MACHINE_PREFIX). The host machine (COS_HOST_PREFIX, default: this machine's prefix) also owns legacy names
# without a `<letter>-` prefix. Several machines share one $COS_DIR (a synced folder); each runs its own chief and
# queue-run.sh and spawns only the tasks addressed `to: <its prefix>`.
COS_PREFIX="$COS_MACHINE_PREFIX"
COS_HOST_PREFIX="${COS_HOST_PREFIX:-$COS_MACHINE_PREFIX}"
export COS_PREFIX COS_HOST_PREFIX
cos_own() {   # cos_own NAME → 0 when this machine may write NAME's task file
  case "$1" in
    "$COS_PREFIX"-*) return 0;;
    [a-z]-*) return 1;;
    *) [ "$COS_PREFIX" = "$COS_HOST_PREFIX" ];;
  esac
}
cos_tmux() {  # tmux on the agent-ops server: COS_TMUX_SOCKET = socket name (-L) or path (-S); unset = default server
  case "${COS_TMUX_SOCKET:-}" in
    "") command tmux "$@";;
    */*) command tmux -S "$COS_TMUX_SOCKET" "$@";;
    *) command tmux -L "$COS_TMUX_SOCKET" "$@";;
  esac
}
cos_mtime() {  # cos_mtime FILE → mtime epoch seconds (GNU stat -c, then BSD stat -f)
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}
# cmux pane helpers (layout, focus guard, pane colour) are not in the plugin: no-ops here, and a user-layer file named
# by COS_CMUX_HELPERS (sourced when it exists) may redefine any of them.
cos_grid_plan() { :; }; cos_focus_snap() { :; }; cos_focus_keep() { :; }; cos_equalize() { :; }
cos_pane_color() { [ -z "${2:-}" ] || printf '%s\n' "$2"; }; cos_send_pane_color() { :; }
[ -z "${COS_CMUX_HELPERS:-}" ] || [ ! -f "$COS_CMUX_HELPERS" ] || . "$COS_CMUX_HELPERS"
cos_skip() {  # cos_skip <integration> <reason> — one-line notice when an optional integration is off
  echo "skip: $1 ($2)" >&2
}
