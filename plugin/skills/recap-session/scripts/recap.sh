#!/usr/bin/env bash
# requires: jq (macOS: brew install jq | Debian/WSL: apt install jq | Git Bash: winget install jqlang.jq)
# recap.sh — extract a readable recap from a Claude Code session .jsonl transcript.
#
# Usage:
#   recap.sh <path-to-session.jsonl>      Recap a specific session file
#   recap.sh --latest [repo-path]         Recap the most-recently-modified session
#                                         for a repo (defaults to $PWD)
#   recap.sh --list   [repo-path]         List recent sessions (mtime, id, title)
#
# Output sections: header, title(s), record-type counts, timespan,
# clean typed user prompts (the human's asks/steering), then the full
# conversation flow (user + assistant text + compact tool calls).
#
# Resolves the Claude projects dir from, in order:
#   $CLAUDE_PROJECTS  |  $CLAUDE_CONFIG_DIR/projects  |  $HOME/.claude/projects
set -eu

# Portability: shared OS helpers (cos_path for Windows paths). Optional — falls back cleanly.
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$_HERE/../../chief-of-staff/scripts/lib/cos-os.sh" ] && . "$_HERE/../../chief-of-staff/scripts/lib/cos-os.sh"
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found (macOS: brew install jq | Debian/WSL: apt install jq | Git Bash: winget install jqlang.jq)" >&2; exit 127; }

# Claude Code names a project dir after the repo path with every non-alphanumeric char → '-'.
# On Git Bash/MSYS the native path is C:\x\y (→ C--x-y), so convert /c/x/y back first.
slug_of() {
  local r="$1"
  if [ "${COS_OS:-}" = windows ] && command -v cygpath >/dev/null 2>&1; then r="$(cygpath -w "$r")"; fi
  printf '%s' "$r" | sed 's#[^A-Za-z0-9]#-#g'
}

resolve_projects() {
  for d in \
    "${CLAUDE_PROJECTS:-}" \
    "${CLAUDE_CONFIG_DIR:-}/projects" \
    "$HOME/.claude/projects"; do
    [ -n "$d" ] && [ -d "$d" ] && { echo "$d"; return 0; }
  done
  echo "ERROR: no Claude projects dir found (set CLAUDE_PROJECTS)" >&2
  return 1
}

# Map an absolute repo path to its ~/.claude/projects folder name (every / -> -).
proj_dir() {
  local projects repo
  projects="$(resolve_projects)"
  repo="$(cd "${1:-$PWD}" 2>/dev/null && pwd || echo "${1:-$PWD}")"
  echo "$projects/$(slug_of "$repo")"
}

# Newest .jsonl in a project dir.
latest_session() {
  ls -t "$1"/*.jsonl 2>/dev/null | head -1
}

list_sessions() {
  local dir; dir="$(proj_dir "${1:-$PWD}")"
  echo "Project dir: $dir"
  echo "----------------------------------------------------------------"
  ls -t "$dir"/*.jsonl 2>/dev/null | head -25 | while read -r f; do
    local id title mtime
    id="$(basename "$f" .jsonl)"
    title="$(jq -r 'select(.type=="ai-title")|.aiTitle' "$f" 2>/dev/null | awk 'NF{x=$0} END{print x}')"
    mtime="$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
    printf '%s  %s  %s\n' "$mtime" "$id" "${title:-<no title>}"
  done
}

recap() {
  local f="$1"
  [ -f "$f" ] || { echo "ERROR: not found: $f" >&2; return 1; }

  echo "================================================================"
  echo "SESSION RECAP: $f"
  echo "  size: $(du -h "$f" | cut -f1)   lines: $(wc -l < "$f" | tr -d ' ')"
  echo "================================================================"

  echo ""; echo "## TITLE(S)"
  jq -r 'select(.type=="ai-title")|.aiTitle' "$f" 2>/dev/null | awk '!seen[$0]++ && NF'

  echo ""; echo "## RECORD TYPES"
  jq -r '.type // "?"' "$f" | sort | uniq -c

  echo ""; echo "## TIMESPAN (UTC)"
  echo "  first: $(jq -r 'select(.timestamp)|.timestamp' "$f" | head -1)"
  echo "  last:  $(jq -r 'select(.timestamp)|.timestamp' "$f" | tail -1)"

  echo ""; echo "## TYPED USER PROMPTS (asks & steering)"
  jq -r '
    select(.type=="user" and ((.isMeta // false)|not) and (.message.content|type=="string"))
    | .message.content
    | select(test("^\\s*<(command|local-command)")|not)
    | select(length>0)
    | "• " + (if length>500 then .[:500] + " …" else . end)
  ' "$f"

  echo ""; echo "## CONVERSATION FLOW"
  jq -r '
    select((.type=="user" or .type=="assistant") and ((.isMeta // false)|not))
    | .message.role as $role
    | (.message.content) as $c
    | if ($c|type)=="string" then
        (if ($c|length)>0 then "[\($role)]: " + $c else empty end)
      elif ($c|type)=="array" then
        ( $c[]
          | if .type=="text" then "[\($role)]: " + .text
            elif .type=="tool_use" then "[\($role) →tool] " + .name + ": " + ((.input|tostring)[:160])
            else empty end )
      else empty end
  ' "$f" | grep -v '^\[.*\]: $' || true
}

main() {
  case "${1:-}" in
    --list)   list_sessions "${2:-$PWD}" ;;
    --latest)
      local dir f; dir="$(proj_dir "${2:-$PWD}")"
      f="$(latest_session "$dir")"
      [ -n "$f" ] || { echo "ERROR: no sessions in $dir" >&2; exit 1; }
      recap "$f" ;;
    "" )      echo "Usage: recap.sh <session.jsonl> | --latest [repo] | --list [repo]" >&2; exit 2 ;;
    * )       recap "$1" ;;
  esac
}
main "$@"
