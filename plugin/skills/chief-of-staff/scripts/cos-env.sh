#!/usr/bin/env bash
# Source me. Loads the agent-ops local config (never in git) and fills core defaults.
COS_CONFIG="${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}"
. "$(dirname "${BASH_SOURCE[0]}")/lib/cos-os.sh"   # cos_source_config, cos_path…
if [ ! -f "$COS_CONFIG" ]; then
  echo "agent-ops: no config at $COS_CONFIG — run /agent-ops:init" >&2
  return 1 2>/dev/null || exit 1
fi
cos_source_config "$COS_CONFIG"   # CRLF-tolerant
# (COS_OS / COS_WSL / COS_PYTHON set in the config win over the detection above)

# Windows paths in config (C:\x) → POSIX (/c/x on Git Bash, /mnt/c/x on WSL). Lists stay colon-separated.
for _v in COS_DIR COS_OUTSTANDING COS_VAULT COS_MONOREPO COS_INVENTORY COS_ACCOUNTS COS_HEAVY_GUARD_ROOT; do
  eval "_x=\${$_v:-}"; [ -z "$_x" ] || eval "$_v=\$(cos_path \"\$_x\")"
done
for _v in COS_LAUNCH_DIRS COS_REMOTE_LAUNCH_DIRS COS_REPO_PATHS; do
  eval "_x=\${$_v:-}"; [ -z "$_x" ] || eval "$_v=\$(cos_path_list \"\$_x\")"
done
unset _v _x

# Core defaults (every add-on var stays empty unless the config sets it)
COS_DIR="${COS_DIR:-$HOME/agent-ops/state}"
COS_OUTSTANDING="${COS_OUTSTANDING:-$COS_DIR/Outstanding.md}"
if [ -z "${COS_LAUNCHER:-}" ]; then   # tmux if installed, else Windows Terminal on Windows/WSL, else print
  if command -v tmux >/dev/null 2>&1; then COS_LAUNCHER=tmux
  elif cos_wt_bin >/dev/null 2>&1; then COS_LAUNCHER=wt
  else COS_LAUNCHER=print; fi
fi
COS_MACHINE_PREFIX="${COS_MACHINE_PREFIX:-m}"
COS_MAX_LOCAL_SESSIONS="${COS_MAX_LOCAL_SESSIONS:-6}"
COS_MIN_FREE_MEM_PCT="${COS_MIN_FREE_MEM_PCT:-20}"
COS_MAX_LOAD_PER_CPU="${COS_MAX_LOAD_PER_CPU:-0.85}"
export COS_CONFIG COS_DIR COS_OUTSTANDING COS_LAUNCHER COS_MACHINE_PREFIX COS_OS COS_WSL COS_PYTHON

mkdir -p "$COS_DIR/tasks" "$COS_DIR/briefs"

# Per-machine ownership: each machine writes only the tasks whose name starts with its own prefix
# (COS_MACHINE_PREFIX). The host machine (COS_HOST_PREFIX, default m) also owns the remote runner's
# workers (COS_REMOTE_MACHINE_PREFIX) and legacy names without a `<letter>-` prefix.
COS_PREFIX="$COS_MACHINE_PREFIX"
COS_HOST_PREFIX="${COS_HOST_PREFIX:-m}"
export COS_PREFIX COS_HOST_PREFIX
cos_own() {   # cos_own NAME → 0 when this machine may write NAME's task file
  case "$1" in
    "$COS_PREFIX"-*) return 0;;
    [a-z]-*) [ "$COS_PREFIX" = "$COS_HOST_PREFIX" ] && [ -n "${COS_REMOTE_MACHINE_PREFIX:-}" ] && [ "${1%%-*}" = "$COS_REMOTE_MACHINE_PREFIX" ];;
    *) [ "$COS_PREFIX" = "$COS_HOST_PREFIX" ];;
  esac
}
cos_remote_host() {  # print the remote runner host (add-on); exit 1 when not configured
  if [ -n "${COS_REMOTE_HOST:-}" ]; then printf '%s\n' "$COS_REMOTE_HOST"; return 0; fi
  [ -n "${COS_INVENTORY:-}" ] && [ -f "$COS_INVENTORY" ] && [ -n "${COS_REMOTE_HOST_KEY:-}" ] || return 1
  cos_python -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['hosts'][sys.argv[2]]['ip'])" "$COS_INVENTORY" "$COS_REMOTE_HOST_KEY" 2>/dev/null
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
cos_skip() {  # cos_skip <integration> <reason> — one-line notice when an optional integration is off
  echo "skip: $1 ($2)" >&2
}
