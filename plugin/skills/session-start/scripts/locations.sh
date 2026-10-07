#!/usr/bin/env bash
# locations.sh — resolve where session files and specs live for the current repo.
# Prints shell assignments, so callers do:  eval "$(bash locations.sh [repo-dir])"
#   SESSIONS_DIR=<abs>   SPECS_DIR=<abs>   CURRENT_SESSION=<abs>/.current-session   LOC_SOURCE=<which rule won>
# Order (first hit wins, per key):
#   1. <repo>/.agent-ops.json        keys "sessionsDir", "specsDir" (relative = relative to repo root)
#   2. agent-ops config               COS_SESSIONS_DIR, COS_SPECS_DIR ($AGENT_OPS_CONFIG or ~/.claude/agent-ops/config.env)
#   3. defaults                       <repo>/sessions, <repo>/specs
# Read-only: never creates directories or writes config. No network.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_LIB="$HERE/../../chief-of-staff/scripts/lib/cos-os.sh"
# shellcheck source=/dev/null
[ -f "$OS_LIB" ] && . "$OS_LIB"
command -v cos_path >/dev/null 2>&1 || cos_path() { printf '%s\n' "$1"; }

start="${1:-$PWD}"
root="$(cd "$start" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || (cd "$start" 2>/dev/null && pwd) || printf '%s' "$start")"
root="$(cos_path "$root")"

sess=""; spec=""; src_s="default"; src_p="default"

# 1. per-project .agent-ops.json (parsed with COS_PYTHON when available; sed fallback for flat JSON)
pj="$root/.agent-ops.json"
if [ -f "$pj" ]; then
  get_key() {
    local v=""
    if command -v cos_python >/dev/null 2>&1; then
      v="$(cos_python -c 'import json,sys
try: d=json.load(open(sys.argv[1], encoding="utf-8"))
except Exception: d={}
v=d.get(sys.argv[2]) if isinstance(d, dict) else None
print(v if isinstance(v, str) else "")' "$pj" "$1" 2>/dev/null | tr -d '\r')"
    fi
    if [ -z "$v" ]; then
      v="$(tr -d '\r\n' <"$pj" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")"
    fi
    printf '%s' "$v"
  }
  s="$(get_key sessionsDir)"; [ -n "$s" ] && { sess="$s"; src_s=".agent-ops.json"; }
  p="$(get_key specsDir)";    [ -n "$p" ] && { spec="$p"; src_p=".agent-ops.json"; }
fi

# 2. agent-ops config (only the two keys are read; the file is not sourced)
cfg="${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}"
if [ -f "$cfg" ]; then
  cfg_val() { sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" "$cfg" | tail -1 | tr -d '\r' | sed "s/^[\"']//; s/[\"']\$//"; }
  [ -z "$sess" ] && { v="$(cfg_val COS_SESSIONS_DIR)"; [ -n "$v" ] && { sess="$v"; src_s="config"; }; }
  [ -z "$spec" ] && { v="$(cfg_val COS_SPECS_DIR)";    [ -n "$v" ] && { spec="$v"; src_p="config"; }; }
fi

# 3. defaults: an existing `_ai/sessions` wins, an existing `_context` wins when specs/ is absent; else <repo>/sessions, <repo>/specs
if [ -z "$sess" ]; then
  if [ -d "$root/_ai/sessions" ]; then sess="_ai/sessions"; src_s="default:_ai/sessions"; else sess="sessions"; fi
fi
if [ -z "$spec" ]; then
  if [ -d "$root/_context" ] && [ ! -d "$root/specs" ]; then spec="_context"; src_p="default:_context"; else spec="specs"; fi
fi

absify() {  # ~ expansion, Windows → POSIX, relative → under repo root
  local p; p="$(cos_path "$1")"
  case "$p" in
    "~"|"~/"*) p="$HOME${p#\~}";;
    \$HOME*) p="$HOME${p#\$HOME}";;
  esac
  case "$p" in
    /*) ;;
    ./*) p="$root/${p#./}";;
    *) p="$root/$p";;
  esac
  printf '%s' "${p%/}"
}
sess="$(absify "$sess")"; spec="$(absify "$spec")"

q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
echo "REPO_ROOT=$(q "$root")"
echo "SESSIONS_DIR=$(q "$sess")"
echo "SPECS_DIR=$(q "$spec")"
echo "CURRENT_SESSION=$(q "$sess/.current-session")"
echo "LOC_SOURCE=$(q "sessions:$src_s specs:$src_p")"
