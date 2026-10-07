#!/usr/bin/env bash
# requires: jq (macOS: brew install jq | Debian/WSL: apt install jq | Git Bash: winget install jqlang.jq)
# mine.sh — extract all raw material from a Claude Code .jsonl transcript in one pass,
# so an agent can synthesize a full /session-update-style file (default) OR a quick recap.
#
# Usage:
#   mine.sh <path-to-session.jsonl>      Mine a specific transcript
#   mine.sh <session-uuid> [repo-path]   Mine by session id (resolved in the repo's project dir)
#   mine.sh --title "<query>" [repo]     Resolve a session by its TITLE (custom-title/ai-title)
#                                        then mine it. Match is case/space/hyphen-insensitive.
#   mine.sh --latest [repo-path]         Mine the newest transcript for a repo (default $PWD)
#   mine.sh --list   [repo-path]         List recent transcripts (mtime, id, title)
#   mine.sh --subagent <agent.jsonl> [outfile]
#                                        Tier-2 deep-read of ONE subagent transcript (mission,
#                                        files changed, verification, internal narrative, final
#                                        return) to STDOUT, or to [outfile] if given. Path from
#                                        the main mine's "## SUBAGENT TRANSCRIPTS" section.
#                                        Parallel-safe: give every run its own outfile.
#
# A title is NOT a filename — it is stored INSIDE the transcript (custom-title.customTitle,
# set by the user, wins; else ai-title.aiTitle, auto). --title / --list search those.
#
# Prints a labelled bundle: header, title history, record counts, timespan, compaction
# status, branch/cwd, typed human prompts, assistant narrative, commit ledger, files
# touched, specs referenced, tool histogram, and a SUBAGENT TRANSCRIPTS inventory (sibling
# subagents/ dir — the per-agent .jsonl the main file does NOT contain). Pipe + Read it:
#   mine.sh <file> > /tmp/mine.txt
#
# Projects dir resolves: $CLAUDE_PROJECTS | $CLAUDE_CONFIG_DIR/projects | $HOME/.claude/projects
# Scratch files go to $MINE_TMPDIR (default $TMPDIR, else /tmp), named per transcript so parallel runs never collide.
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

MINE_TMPDIR="${MINE_TMPDIR:-${TMPDIR:-/tmp}}"; MINE_TMPDIR="${MINE_TMPDIR%/}"

# Paths of Edit/Write/NotebookEdit calls whose tool_result is NOT an error. A write a hook or a
# permission check refused is stored as is_error:true and never landed, so it is not a change.
# $2 = "ok" (default) lists landed writes; "refused" lists the refused ones.
edit_paths() {
  jq -rs --arg want "${2:-ok}" '
    (reduce (.[] | select(.type=="user") | .message.content
             | if type=="array" then .[] else empty end
             | select(.type=="tool_result" and .is_error==true) | .tool_use_id) as $i
      ({}; .[$i] = true)) as $err
    | .[] | select(.type=="assistant") | .message.content
    | if type=="array" then .[] else empty end
    | select(.type=="tool_use" and (.name|test("^(Edit|MultiEdit|Write|NotebookEdit)$")))
    | select(if $want=="refused" then ($err[.id] // false) else (($err[.id] // false) | not) end)
    | .input.file_path // .input.notebook_path // empty
  ' "$1" 2>/dev/null
}

resolve_projects() {
  for d in "${CLAUDE_PROJECTS:-}" "${CLAUDE_CONFIG_DIR:-}/projects" \
           "$HOME/.claude/projects"; do
    [ -n "$d" ] && [ -d "$d" ] && { echo "$d"; return 0; }
  done
  echo "ERROR: no Claude projects dir (set CLAUDE_PROJECTS)" >&2; return 1
}
proj_dir() {
  local p r; p="$(resolve_projects)"
  r="$(cd "${1:-$PWD}" 2>/dev/null && pwd || echo "${1:-$PWD}")"
  echo "$p/$(slug_of "$r")"
}

# The session's display title: latest custom-title (user-set) wins, else latest ai-title.
title_of() {
  local t
  t="$(jq -r 'select(.type=="custom-title")|.customTitle // empty' "$1" 2>/dev/null | tail -1)"
  [ -z "$t" ] && t="$(jq -r 'select(.type=="ai-title")|.aiTitle // empty' "$1" 2>/dev/null | tail -1)"
  printf '%s' "$t"
}
# Normalize for fuzzy title match: lowercase, collapse runs of [-_ ] to one space, trim.
norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[-_ ][-_ ]*/ /g; s/^ //; s/ $//'; }

# Echo "<file>\t<title>" for every transcript whose title contains the query (normalized).
resolve_title() {
  local dir q qn t; dir="$(proj_dir "${2:-$PWD}")"; q="$1"; qn="$(norm "$q")"
  for f in "$dir"/*.jsonl; do
    [ -e "$f" ] || continue
    t="$(title_of "$f")"; [ -z "$t" ] && continue
    case "$(norm "$t")" in *"$qn"*) printf '%s\t%s\n' "$f" "$t" ;; esac
  done
}

list_sessions() {
  local dir; dir="$(proj_dir "${1:-$PWD}")"
  echo "Project dir: $dir"; echo "------------------------------------------------"
  ls -t "$dir"/*.jsonl 2>/dev/null | head -25 | while read -r f; do
    local id mt t; id="$(basename "$f" .jsonl)"
    t="$(title_of "$f")"; mt="$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
    printf '%s  %s  %s\n' "$mt" "$id" "${t:-<no title>}"
  done
}

mine() {
  local f="$1"
  [ -f "$f" ] || { echo "ERROR: not found: $f" >&2; return 1; }

  echo "=================================================================="
  echo "TRANSCRIPT: $f"
  echo "  id: $(basename "$f" .jsonl)   size: $(du -h "$f"|cut -f1)   lines: $(wc -l <"$f"|tr -d ' ')"
  echo "  title: $(title_of "$f")"
  echo "=================================================================="

  echo ""; echo "## TITLE HISTORY (custom-title wins; ai-title auto)"
  jq -r 'select(.type=="custom-title")|"custom: "+(.customTitle//"")' "$f" 2>/dev/null | awk 'NF&&!s[$0]++'
  jq -r 'select(.type=="ai-title")|"ai:     "+(.aiTitle//"")' "$f" 2>/dev/null | awk 'NF&&!s[$0]++'

  echo ""; echo "## RECORD TYPES"
  jq -r '.type // "?"' "$f" | sort | uniq -c | sort -rn

  echo ""; echo "## TIMESPAN (UTC, first→last)"
  jq -r 'select(.type=="assistant" or .type=="user")|.timestamp // empty' "$f" | sed -n '1p;$p'

  echo ""; echo "## COMPACTION"
  local nc
  nc=$(jq -r 'select(.type=="user")|.message.content|select(type=="string")' "$f" 2>/dev/null \
       | grep -c 'continued from a previous conversation' || true)
  echo "  continuation markers: ${nc:-0}  (>0 ⇒ session was compacted; pre-marker detail is summarized, not lost)"

  echo ""; echo "## BRANCH / CWD"
  jq -r 'select(.gitBranch)|.gitBranch' "$f" 2>/dev/null | awk 'NF&&!s[$0]++' | sed 's/^/  branch: /'
  jq -r 'select(.cwd)|.cwd' "$f" 2>/dev/null | awk '!s[$0]++' | sed 's/^/  cwd: /'

  echo ""; echo "## TYPED HUMAN PROMPTS (intent spine — robust to missing promptSource)"
  jq -r '
    select(.type=="user")
    | select((.promptSource==null) or .promptSource=="typed" or .promptSource=="queued")
    | select((.isMeta // false)|not)
    | (.message.content) as $c
    | (if ($c|type)=="string" then $c
       elif ($c|type)=="array" then ($c[]|select(.type=="text")|.text)
       else empty end)
    | select(test("^\\s*<(command|local-command|system-reminder)")|not)
    | select(test("continued from a previous conversation")|not)
    | select(length>0)
    | "• " + (if length>600 then .[:600]+" …" else . end)
  ' "$f" 2>/dev/null

  local assist="$MINE_TMPDIR/mine_assist_$(basename "$f" .jsonl).txt"
  echo ""; echo "## ASSISTANT NARRATIVE → $assist (Read it; not inlined)"
  jq -r 'select(.type=="assistant")|.message.content|if type=="array" then (.[]|select(.type=="text")|.text) else empty end' \
    "$f" 2>/dev/null | grep -v '^[[:space:]]*$' > "$assist" || true
  echo "  lines: $(wc -l <"$assist" 2>/dev/null | tr -d ' ')"

  echo ""; echo "## COMMIT LEDGER (short hashes mentioned in narrative)"
  grep -oE '`[0-9a-f]{7,8}`' "$assist" 2>/dev/null | tr -d '`' | sort -u | tr '\n' ' '; echo

  echo ""; echo "## FILES TOUCHED (Edit/Write/NotebookEdit that landed; refused writes excluded)"
  edit_paths "$f" ok | sort -u
  local refused; refused="$(edit_paths "$f" refused | sort -u)"
  if [ -n "$refused" ]; then
    echo ""; echo "## WRITES REFUSED (hook/permission error — never landed; often a discarded approach)"
    printf '%s\n' "$refused"
  fi

  echo ""; echo "## SPECS REFERENCED"
  grep -oE '[A-Za-z0-9_./-]*specs/[A-Za-z0-9_./-]+' "$f" 2>/dev/null | sort -u   # paths under any <specs-dir>

  echo ""; echo "## TOOL HISTOGRAM"
  jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.name' "$f" 2>/dev/null | sort | uniq -c | sort -rn

  # ── The tail: where the session STOPPED. For a handoff this matters more than anything above —
  # it shows what Claude was waiting for, or what was mid-flight, when the user walked away.
  echo ""; echo "## TAIL — last 20 events (where the session stopped; read this FIRST for a handoff)"
  jq -r '
    def cut($n): gsub("\\s+";" ") | if length>$n then .[0:$n]+"…" else . end;
    def ts: (.timestamp // "" | .[11:19]);
    select(.type=="user" or .type=="assistant")
    | ts as $t | .type as $ty | (.message.content) as $c
    | if ($c|type)=="string" then
        (if ($c|test("<task-notification>")) then "\($t) NOTIFY  " + ($c|cut(260))
         elif ($c|test("^<(command|local-command)|system-reminder")) then empty
         else "\($t) USER    " + ($c|cut(400)) end)
      else $c[] |
        if .type=="text" and $ty=="assistant" then "\($t) CLAUDE  " + (.text|cut(400))
        elif .type=="text" and $ty=="user" then
          (if (.text|test("<task-notification>")) then "\($t) NOTIFY  " + (.text|cut(260))
           elif (.text|test("^<(command|local-command)|system-reminder")) then empty
           else "\($t) USER    " + (.text|cut(400)) end)
        elif .type=="tool_use" then "\($t) TOOL    \(.name)" + (if .input.run_in_background==true then " [background]" else "" end) + ": " + ((.input.description // .input.command // .input.prompt // .input.file_path // (.input|tostring))|tostring|cut(160))
        elif .type=="tool_result" then "\($t) RESULT  " + (if .is_error==true then "[ERROR] " else "" end) + ((.content|if type=="array" then (map(.text? // "")|join(" ")) else tostring end)|cut(200))
        else empty end
      end' "$f" 2>/dev/null | tail -20

  echo ""; echo "## WAITING ON AT HAND-OFF — background launches vs completion notices (a launch with no later NOTIFY was still open)"
  jq -r '
    def cut($n): gsub("\\s+";" ") | if length>$n then .[0:$n]+"…" else . end;
    (.timestamp // "" | .[0:19]) as $t
    | if .type=="assistant" then
        .message.content[]? | select(.type=="tool_use")
        | select(.input.run_in_background==true or (.name|IN("Agent","Task","Monitor","ScheduleWakeup","CronCreate","Workflow","RemoteTrigger")))
        | "\($t) LAUNCH  \(.name): " + ((.input.description // .input.prompt // .input.command // "")|tostring|cut(140))
      elif .type=="user" then
        (.message.content | if type=="string" then . else (map(.text? // "")|join(" ")) end)
        | select(test("<task-notification>"))
        | "\($t) NOTIFY  " + ([ ([capture("<task-id>(?<v>[^<]*)</task-id>")][0].v), ([capture("<status>(?<v>[^<]*)</status>")][0].v), ([capture("<summary>(?<v>[^<]*)</summary>")][0].v), ([capture("<event>(?<v>[^<]*)</event>")][0].v) ] | map(select(.!=null)) | join(" | ") | cut(220))
      else empty end' "$f" 2>/dev/null | tail -25

  echo ""; echo "## TOOL CALLS WITH NO RESULT (session died or was interrupted mid-call)"
  jq -rs '
    [ .[] | select(.type=="user") | .message.content | arrays | .[] | select(.type=="tool_result") | .tool_use_id ] as $done
    | .[] | select(.type=="assistant") | (.timestamp // "" | .[0:19]) as $t
    | .message.content[]? | select(.type=="tool_use") | select(.id as $i | $done | index($i) | not)
    | "\($t) \(.name): " + ((.input.description // .input.command // .input.prompt // "")|tostring|.[0:160])' "$f" 2>/dev/null | tail -10

  echo ""; echo "## SUBAGENT TRANSCRIPTS (per-agent .jsonl, sibling dir — NOT in the main file)"
  # Sub-agent (Task/Agent-tool) turns are persisted separately at <transcript>/subagents/agent-*.jsonl.
  # The MAIN transcript keeps only each agent's RETURNED summary (as a tool_result); the agent's
  # internal steps — exact edits, discarded hypotheses, real test output, incident ground truth —
  # live ONLY here. Tier-1 inventory below; deep-read a [HIGH] one with:  mine.sh --subagent <file>
  local sdir="${f%.jsonl}/subagents"
  if [ -d "$sdir" ] && ls "$sdir"/agent-*.jsonl >/dev/null 2>&1; then
    echo "  dir: $sdir"
    echo "  ($(ls "$sdir"/agent-*.jsonl 2>/dev/null | wc -l | tr -d ' ') files, $(du -sh "$sdir" 2>/dev/null | cut -f1)) — [HIGH]=deep-read (implementer/debug/incident), [low]=return summary suffices"
    for x in "$sdir"/agent-*.jsonl; do
      [ -e "$x" ] || continue
      local ln edits bashes tools mission tier
      ln=$(wc -l <"$x" | tr -d ' ')
      edits=$(edit_paths "$x" ok | grep -c . || true)
      bashes=$(jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use" and .name=="Bash")|.name' "$x" 2>/dev/null | grep -c . || true)
      tools=$(jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.name' "$x" 2>/dev/null | sort | uniq -c | sort -rn | awk '{printf "%s×%s ",$2,$1}')
      mission=$(jq -r 'select(.type=="user")|.message.content|if type=="string" then . elif type=="array" then (.[]|select(.type=="text")|.text) else empty end' "$x" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1 | tr '\n' ' ' | cut -c1-90)
      # HIGH value = an implementer (many edits) OR a debug/incident/rollback mission — its process is worth reading.
      if [ "${edits:-0}" -ge 10 ] || printf '%s' "$mission" | grep -qiE 'debug|regression|rollback|revert|incident|urgent|root cause|evidence-first|fix .*(dev|prod|bug)'; then
        tier="HIGH"
      else
        tier="low "
      fi
      printf '  [%s] %-30s %5s ln | %s\n         ↳ %s\n' "$tier" "$(basename "$x")" "$ln" "${tools% }" "$mission"
    done
    echo "  deep-read a HIGH one:  $0 --subagent $sdir/<agent-id>.jsonl > $MINE_TMPDIR/mine_sub_<agent-id>.txt"
    echo "  (one outfile per agent — safe to run several in parallel)"
  else
    echo "  none (session predates per-subagent persistence, or spawned no Agent-tool subagents)"
  fi
}

# Tier-2: deep-read ONE subagent transcript — the process the main transcript's return summary drops.
# Prints mission, files changed (count/path), refused writes, verification/key bash, full internal
# narrative, and the final return block. STDOUT by default; with an outfile it writes there and says
# so on STDERR (never on stdout, so a redirect can't mix the notice into the report).
subagent_report() {
  local sf="$1" out="${2:-}"
  [ -f "$sf" ] || { echo "ERROR: subagent transcript not found: $sf" >&2; return 1; }
  if [ -z "$out" ]; then subagent_body "$sf"; return; fi
  subagent_body "$sf" > "$out"
  echo "Wrote $out ($(wc -l <"$out" | tr -d ' ') lines) — Read it. Fold FILES CHANGED → Build state, discarded hypotheses → Lessons, VERIFICATION → confidence." >&2
}

subagent_body() {
  local sf="$1" refused
    echo "=================================================================="
    echo "SUBAGENT: $sf"
    echo "  lines: $(wc -l <"$sf" | tr -d ' ')   size: $(du -h "$sf" | cut -f1)"
    echo "=================================================================="
    echo ""; echo "## MISSION (task prompt handed to the subagent — first user text)"
    jq -r 'select(.type=="user")|.message.content|if type=="string" then . elif type=="array" then (.[]|select(.type=="text")|.text) else empty end' \
      "$sf" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1
    echo ""; echo "## FILES CHANGED (Edit/Write/NotebookEdit that landed — count per path; the precise diff locus)"
    edit_paths "$sf" ok | sort | uniq -c | sort -rn
    refused="$(edit_paths "$sf" refused | sort | uniq -c | sort -rn)"
    if [ -n "$refused" ]; then
      echo ""; echo "## WRITES REFUSED (hook/permission error — never landed; often a discarded approach)"
      printf '%s\n' "$refused"
    fi
    echo ""; echo "## VERIFICATION / KEY BASH (test/tsc/pnpm/vitest/git/deploy — evidence, not claims)"
    jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use" and .name=="Bash")|.input.command // empty' \
      "$sf" 2>/dev/null | grep -iE 'test|tsc|pnpm|vitest|jest|git (merge|push|revert|reset|log|status|cherry)|deploy|docker|curl|redis|narration' | head -50
    echo ""; echo "## INTERNAL NARRATIVE (the subagent's own reasoning — incl. discarded hypotheses)"
    jq -r 'select(.type=="assistant")|.message.content|if type=="array" then (.[]|select(.type=="text")|.text) else empty end' \
      "$sf" 2>/dev/null | grep -v '^[[:space:]]*$'
    echo ""; echo "## FINAL RETURN (last assistant text = what it reported back to the parent)"
    jq -r 'select(.type=="assistant")|.message.content|if type=="array" then (.[]|select(.type=="text")|.text) else empty end' \
      "$sf" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -40
}

# Resolve a non-path, non-uuid argument (a title/name) to a file, then mine.
mine_by_title() {
  local q="$1" repo="${2:-$PWD}" hits n
  hits="$(resolve_title "$q" "$repo")"
  n="$(printf '%s' "$hits" | grep -c . || true)"
  if [ "${n:-0}" -eq 0 ]; then
    echo "No session title matches: \"$q\"  (searched custom-title + ai-title in $(proj_dir "$repo"))" >&2
    echo "Run:  mine.sh --list   to see available titles." >&2
    return 1
  elif [ "$n" -eq 1 ]; then
    mine "$(printf '%s' "$hits" | head -1 | cut -f1)"
  else
    echo "Multiple sessions match \"$q\" — disambiguate by id:" >&2
    printf '%s\n' "$hits" | while IFS="$(printf '\t')" read -r f t; do
      echo "  $(basename "$f" .jsonl)  —  $t" >&2
    done
    return 2
  fi
}

is_uuid() { printf '%s' "$1" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }

case "${1:-}" in
  --list)   list_sessions "${2:-$PWD}" ;;
  --title)  [ -n "${2:-}" ] || { echo "Usage: mine.sh --title \"<query>\" [repo]" >&2; exit 2; }
            mine_by_title "$2" "${3:-$PWD}" ;;
  --latest) # newest transcript that is NOT the session running this script (that one is always newest)
            f="$(ls -t "$(proj_dir "${2:-$PWD}")"/*.jsonl 2>/dev/null | grep -v "/${CLAUDE_CODE_SESSION_ID:-__none__}\.jsonl$" | head -1)"
            [ -n "$f" ] || { echo "ERROR: no transcripts found" >&2; exit 1; }; mine "$f" ;;
  --subagent) [ -n "${2:-}" ] || { echo "Usage: mine.sh --subagent <.../subagents/agent-<id>.jsonl> [outfile]" >&2; exit 2; }
            subagent_report "$2" "${3:-}" ;;
  "" )      echo "Usage: mine.sh <session.jsonl|uuid> | --title \"<q>\" | --latest [repo] | --list [repo] | --subagent <agent.jsonl>" >&2; exit 2 ;;
  * )       if [ -f "$1" ]; then mine "$1"
            elif is_uuid "$1"; then mine "$(proj_dir "${2:-$PWD}")/$1.jsonl"
            else mine_by_title "$1" "${2:-$PWD}"; fi ;;   # not a path / uuid → treat as a title query
esac
