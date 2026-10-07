#!/usr/bin/env bash
# Spawn a Claude worker session that works from a task file and reports back through that same file.
#   spawn.sh --task-file tasks/NAME.md [overrides…]       (the one way in — a queued or hand-written task)
#   spawn.sh --name NAME --dir DIR --model sonnet|opus --charter FILE   (legacy: builds tasks/NAME.md from the charter)
#            [--agent NAME] [--remote] [--dry-run] [--no-goal] [--depends-on WORKER]... [--story-list FILE]
#            [--light] [--force] [--account a|<id>|auto] [--continues OLD-WORKER] [--resume UUID] [--workspace REF]
#   --task-file F  frontmatter gives name, dir, model, agent, account, depends_on_missions, story_list (flags override);
#                  its body is the charter. `to:` must be this machine's prefix; status must be open|claimed (else
#                  exit 2 unless --force). The worker reports under `## Reports` of that file and asks the owner via `asks:`.
#   Launcher       COS_LAUNCHER (config): print = print the exact claude command + task file path, open nothing;
#                  tmux = new window in tmux session `agent-ops`; cmux = new pane in the chief's cmux workspace (add-on).
#   --agent NAME   passed through as `claude --agent NAME`.
#   --dry-run      print the goal, the task file and the launch commands; write nothing, launch nothing.
#   --no-goal      allow a charter that says `parent goal: none` (PARK risk).
#   --depends-on W another worker that must finish first (repeatable).
#   --story-list F the feature's story_list.json (else the charter's `story list:` line).
#   --light        read-only worker: may start while load-check says OFFLOAD.  --force: start anyway.
#   --account ID   accounts add-on (COS_DEFAULT_ACCOUNT / COS_ACCOUNTS set): a = default login; b, c… = token in
#                  Keychain item cos-claude-account-<id> (addons/account-add.sh); auto = least-loaded ok account.
#                  Unconfigured → always a. The token is never written anywhere (only the id is).
#   --continues OLD  continue OLD's work: its session file first (when current), else its transcript. Local only.
#   --resume UUID  reopen a STOPPED worker's own session with the same launch flags (keeps the prompt cache). Local only.
#   --workspace REF  cmux launcher only: the workspace the pane opens in.
# Launch-dir guard: --dir must be exactly one of $COS_LAUNCH_DIRS (colon-separated). --remote (add-on): --dir must
#   match a LOCAL=REMOTE pair in $COS_REMOTE_LAUNCH_DIRS.
# Load gate: load-check.sh OFFLOAD refuses a local worker (exit 3) unless --light or --force.
# Goal gate: the charter carries `task goal:`, `done means:` and `parent goal: <ID>` (a `### <ID> · ` heading in
#   $COS_GOALS, default $COS_DIR/GOALS.md). Missing task goal or unknown/parked parent → exit 2.
# NAME convention: <machine>-<topic>[-<specifier>][-N], lowercase, hyphen-joined; machine = $COS_MACHINE_PREFIX.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"

# Launch scripts live under $LAUNCH_DIR. If COS_VAULT is set, vault paths reach argv only through a symlink
# alias (devault) so process-matching watchdogs that key on the vault path never hit a worker.
LAUNCH_DIR="${COS_LAUNCH_SCRIPT_DIR:-$COS_DIR/launch}"
[ "${DRY:-0}" = 1 ] || mkdir -p "$LAUNCH_DIR" 2>/dev/null || true
if [ -n "${COS_VAULT:-}" ]; then
  VAULT_ALIAS="${COS_VAULT_ALIAS:-$HOME/.claude/agent-ops/vault}"
  ln -sfn "$COS_VAULT" "$VAULT_ALIAS"
  devault() { case "$1" in "$COS_VAULT"|"$COS_VAULT"/*) printf '%s' "$VAULT_ALIAS${1#$COS_VAULT}";; *) printf '%s' "$1";; esac; }
else
  devault() { printf '%s' "$1"; }
fi

TASKF= TCOLOR_OVR= MODEL_SET=0 NAME= DIR= MODEL=opus TASK= CHARTER= REMOTE=0 AGENT= DRY=0 NOGOAL=0 LIGHT=0 FORCE=0 STORYLIST= DEPS=() ACCT= ACCT_SET=0 CONT= PRED= PSESS= RESUME= MODEL_SRC=default CONT_WHY= WS_ARG="${COS_SPAWN_WORKSPACE:-}"
while [ $# -gt 0 ]; do case "$1" in
  --name) NAME="$2"; shift 2;; --dir) DIR="$2"; shift 2;; --model) MODEL="$2"; MODEL_SET=1; MODEL_SRC=flag; shift 2;; --task-file) TASKF="$2"; shift 2;;
  --task) TASK="$2"; shift 2;; --charter) CHARTER="$2"; shift 2;; --remote) REMOTE=1; shift;;
  --agent) AGENT="$2"; shift 2;; --dry-run) DRY=1; shift;; --no-goal) NOGOAL=1; shift;;
  --depends-on) DEPS+=("$2"); shift 2;; --story-list) STORYLIST="$2"; shift 2;;
  --light) LIGHT=1; shift;; --force) FORCE=1; shift;; --account) ACCT="$2"; ACCT_SET=1; shift 2;;
  --continues) CONT="$2"; shift 2;; --workspace) WS_ARG="$2"; shift 2;; --resume) RESUME="$2"; shift 2;;
  -h|--help) awk 'NR>1 && /^set -euo/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"; exit 0;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; done
TPY="$HERE/lib/tasks.py"
if [ -n "$TASKF" ]; then
  [ -f "$TASKF" ] || { echo "refuse: no task file $TASKF" >&2; exit 2; }
  tget() { cos_python "$TPY" get "$TASKF" "$1"; }
  [ -n "$NAME" ] || NAME=$(tget name)
  [ -n "$DIR" ] || DIR=$(tget dir)
  [ "$MODEL_SET" = 1 ] || { m=$(tget model); [ -z "$m" ] || { MODEL="$m"; MODEL_SRC=task; }; }
  [ -n "$AGENT" ] || AGENT=$(tget agent)
  [ "$ACCT_SET" = 1 ] || { ACCT=$(tget account); [ -z "$ACCT" ] || ACCT_SET=1; }
  [ -n "$STORYLIST" ] || STORYLIST=$(tget story_list)
  [ -n "$CONT" ] || [ -n "$RESUME" ] || CONT=$(tget continues)   # resume = the SAME session, no predecessor step
  TCOLOR_OVR=$(tget color)   # optional `color:` override for the pane colour (lib/pane-color.sh)
  [ "$(tget light)" != true ] || LIGHT=1   # read-only task: may start while load says OFFLOAD
  if [ "${#DEPS[@]}" = 0 ]; then while IFS= read -r d; do [ -z "$d" ] || DEPS+=("$d"); done < <(cos_python -c 'import json,sys;[print(x) for x in json.loads(sys.argv[1] or "[]")]' "$(tget depends_on_missions)"); fi
  TST=$(tget status); TTO=$(tget to)
  [ -n "$RESUME" ] || case "$TST" in open|claimed|"") ;; *) echo "refuse: task $NAME is '$TST' — only open|claimed tasks spawn (--force to respawn)" >&2; [ "$FORCE" = 1 ] || exit 2;; esac
  CHARTER="$TASKF"
fi
[ -n "$NAME" ] || { echo "need --task-file FILE, or --name --dir --charter FILE" >&2; exit 2; }
# Naming convention — checked before anything else so a bad name never gets half-spawned.
MACH_LOCAL="${COS_MACHINE_PREFIX:-m}"
MACH_REMOTE="${COS_REMOTE_MACHINE_PREFIX:-}"
if [ "$REMOTE" = 1 ] && [ -z "$MACH_REMOTE" ]; then
  echo "COS_REMOTE_MACHINE_PREFIX is unset — remote runner add-on not configured (set it in config.env via /agent-ops:init)" >&2; exit 2
fi
LETTERS="a-z"
if ! [[ "$NAME" =~ ^[${LETTERS}](-[a-z0-9]+){1,3}$ ]]; then
  echo "bad --name '$NAME'. Rule: <machine>-<topic>[-<specifier>][-N], lowercase a-z0-9, hyphen-joined, 2-4 parts." >&2
  echo "  machine: $MACH_LOCAL = this machine${MACH_REMOTE:+, $MACH_REMOTE = remote runner}. Examples: $MACH_LOCAL-auth-fix, $MACH_LOCAL-docs-2" >&2
  exit 2
fi
if [ "$REMOTE" = 1 ]; then
  [ "${NAME%%-*}" = "$MACH_REMOTE" ] || { echo "remote worker name must start with '$MACH_REMOTE-' (COS_REMOTE_MACHINE_PREFIX), got '$NAME'" >&2; exit 2; }
elif [ "${NAME%%-*}" != "$MACH_LOCAL" ]; then
  # Per-machine ownership: this machine writes only its own prefix's tasks.
  echo "refuse: local worker name must start with '$MACH_LOCAL-' (COS_MACHINE_PREFIX on this machine), got '$NAME' — spawn it on its own machine, or --force" >&2
  [ "$FORCE" = 1 ] || exit 2
fi
[ -z "$TASKF" ] || [ -z "$TTO" ] || [ "$TTO" = "${NAME%%-*}" ] || { echo "refuse: task $NAME is addressed to '$TTO', not this name's machine '${NAME%%-*}'" >&2; exit 2; }
[ -n "$DIR" ] && [ -n "$CHARTER" ] && [ -f "$CHARTER" ] || { echo "need --dir and a charter/task file (--task-file F | --charter F)" >&2; exit 2; }
# Resume — same session, same flags; anything that would change the cached prompt is refused or WARNed.
RTRANS=
if [ -n "$RESUME" ]; then
  [[ "$RESUME" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "bad --resume '$RESUME' — a session uuid" >&2; exit 2; }
  [ -n "$TASKF" ] || { echo "refuse: --resume needs --task-file tasks/<name>.md (model, dir, agent, account come from it)" >&2; exit 2; }
  [ "$REMOTE" = 0 ] || { echo "refuse: --resume is local only" >&2; exit 2; }
  [ -z "$CONT" ] || { echo "refuse: --resume and --continues don't mix — resume reopens the SAME session" >&2; exit 2; }
  RTRANS="$HOME/.claude/projects/$(printf '%s' "${DIR%/}" | tr '/.' '--')/$RESUME.jsonl"
  if [ ! -f "$RTRANS" ]; then
    other=; for f in "$HOME"/.claude/projects/*/"$RESUME".jsonl; do [ -f "$f" ] && { other="$f"; break; }; done
    [ -z "$other" ] && echo "refuse: no transcript $RESUME.jsonl under ~/.claude/projects/ — wrong session id?" >&2 \
      || echo "refuse: transcript is $other, not under --dir $DIR's project — the session ran from another dir (cwd is part of the cached prompt); fix the task's dir:" >&2
    exit 2
  fi
  TMODEL=$(cos_python - "$RTRANS" <<'PYM'
import json, sys
last = ""
for l in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if '"assistant"' not in l: continue
    try: d = json.loads(l)
    except Exception: continue
    m = (d.get("message") or {}).get("model") or ""
    if d.get("type") == "assistant" and m and not m.startswith("<"): last = m
print(last)
PYM
)
  case "$TMODEL" in *opus*) TALIAS=opus;; *sonnet*) TALIAS=sonnet;; *) TALIAS=;; esac
  if [ "$MODEL_SRC" = default ]; then
    [ -n "$TALIAS" ] || { echo "refuse: task has no model: and the transcript's last model '${TMODEL:-none}' maps to no spawn alias (opus|sonnet) — set model: in the task file" >&2; exit 2; }
    MODEL="$TALIAS"; MODEL_SRC="transcript ($TMODEL)"
  elif [ -n "$TALIAS" ] && [ "$TALIAS" != "$MODEL" ]; then
    echo "WARN: resuming with --model $MODEL ($MODEL_SRC) but the transcript last ran $TMODEL — a model change re-reads the whole context (cache miss)" >&2
  fi
  TACCT=$(tget account)
  [ -n "$ACCT" ] && [ "$ACCT" != auto ] || { echo "refuse: --resume needs the session's own account — task has no account: and no --account given (auto/default could pick another login = cache miss)" >&2; exit 2; }
  [ -z "$TACCT" ] || [ "$TACCT" = "$ACCT" ] || echo "WARN: account $ACCT differs from the task's account $TACCT — changing account loses the prompt cache; tell the owner first" >&2
  # Live check — one session, one process. Kill (stop.sh NAME) must come first.
  LIVE=$(cos_python - "$RESUME" "$NAME" <<'PYL'
import glob, json, os, sys
sid, name = sys.argv[1:]
for f in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try: d = json.load(open(f)); os.kill(d.get("pid"), 0)
    except Exception: continue
    if d.get("sessionId") == sid or d.get("name") == name: print(f"pid {d.get('pid')} ({d.get('name') or '-'}, session {d.get('sessionId')})"); break
PYL
)
  [ -n "$LIVE" ] || LIVE=$("$HERE/sessions.sh" --tsv 2>/dev/null | awk -F'\t' -v n="$NAME" '$1=="live" && $2==n {print "pid " $3 " (" n ")"; exit}')
  if [ -n "$LIVE" ]; then
    if [ "$DRY" = 1 ] && [ "$FORCE" = 1 ]; then echo "WARN: $NAME / session $RESUME still live: $LIVE — dry-run only (--force); a real resume refuses until it is stopped" >&2
    else echo "refuse: $NAME / session $RESUME still has a live process: $LIVE — stop it first (stop.sh $NAME), then resume" >&2; exit 2; fi
  fi
  TASKP_RESUME="$TASKF"
fi
case "$MODEL" in sonnet|opus) ;; *) echo "model must be sonnet|opus" >&2; exit 2;; esac
[ -z "$AGENT" ] || [[ "$AGENT" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "agent must be [A-Za-z0-9._:-]" >&2; exit 2; }
AGENT_FLAG=; [ -n "$AGENT" ] && AGENT_FLAG="--agent $AGENT "
for d in "${DEPS[@]+"${DEPS[@]}"}"; do [[ "$d" =~ ^[a-z](-[a-z0-9]+){1,3}$ ]] || { echo "bad --depends-on '$d' — a worker name" >&2; exit 2; }; done

# Launch-dir guard — Claude sessions start ONLY from the approved roots.
DIRN="${DIR%/}"; ok=0; RDIR=
if [ "$REMOTE" = 1 ]; then
  ALLOWED="${COS_REMOTE_LAUNCH_DIRS:-}"
  [ -n "$ALLOWED" ] || { echo "refuse: COS_REMOTE_LAUNCH_DIRS unset in $COS_CONFIG — LOCAL=REMOTE pairs, e.g. <repo-root>=code/repo" >&2; exit 2; }
  IFS=: read -r -a _dirs <<< "$ALLOWED"
  for a in "${_dirs[@]}"; do
    l="${a%%=*}"; r="${a#*=}"; [ "$a" != "$l" ] || { echo "refuse: COS_REMOTE_LAUNCH_DIRS entry '$a' is not LOCAL=REMOTE" >&2; exit 2; }
    r="${r%/}"; r="${r#\~/}"
    [[ "$r" =~ ^[A-Za-z0-9._-][A-Za-z0-9._/-]*$ ]] && [[ "$r" != *..* ]] || { echo "refuse: remote dir '$r' must be a plain path under the remote \$HOME" >&2; exit 2; }
    case "$DIRN" in "${l%/}"|"$r"|"~/$r"|"/Users/$COS_REMOTE_USER/$r") ok=1; RDIR="$r";; esac
  done
  [ "$ok" = 1 ] || { echo "refuse: --dir '$DIR' has no remote checkout. Mapped: ${ALLOWED//:/ | }" >&2
    echo "  Seed the repo on the remote first (git push from this machine), then add LOCAL=REMOTE." >&2; exit 2; }
else
  ALLOWED="${COS_LAUNCH_DIRS:-}"
  [ -n "$ALLOWED" ] || { echo "refuse: COS_LAUNCH_DIRS unset in $COS_CONFIG — list the approved launch dirs (colon-separated)" >&2; exit 2; }
  IFS=: read -r -a _dirs <<< "$ALLOWED"
  for a in "${_dirs[@]}"; do [ "$DIRN" = "${a%/}" ] && ok=1; done
  [ "$ok" = 1 ] || { echo "refuse: --dir '$DIR' is not a launch dir. Allowed: ${ALLOWED//:/ | }" >&2
    echo "  Launch from one of those; name the repo the worker works in inside the charter." >&2; exit 2; }
fi

# Account (add-on) — which Claude login the worker uses. Only the id is ever recorded; the token stays in the Keychain.
ACCTS_ON=0; [ -n "${COS_DEFAULT_ACCOUNT:-}${COS_ACCOUNTS:-}" ] && ACCTS_ON=1
[ -n "$ACCT" ] || ACCT="${COS_DEFAULT_ACCOUNT:-a}"   # (--resume refused an empty/auto account above)
[[ "$ACCT" =~ ^([a-z][a-z0-9]{0,5}|auto)$ ]] || { echo "bad --account '$ACCT' — a, b, c… or auto" >&2; exit 2; }
if [ "$REMOTE" = 1 ]; then
  [ "$ACCT_SET" = 0 ] || echo "NOTE: --account ignored with --remote — the remote runner uses its own login" >&2
  ACCT=remote
elif [ "$ACCTS_ON" = 0 ]; then
  [ "$ACCT" = a ] || echo "skip: accounts add-on not configured — using the default login (a)" >&2
  ACCT=a
else
  if [ "$ACCT" = auto ]; then
    ACCT=$("$HERE/addons/account-limit.sh" --pick) || { rc=$?; [ "$rc" = 4 ] && exit 4; echo "account-limit.sh --pick failed (exit $rc)" >&2; exit 1; }
  else
    "$HERE/addons/account-limit.sh" --show 2>/dev/null | awk -v a="$ACCT" '$1==a && $2=="limited" {f=1} END {exit !f}' \
      && echo "WARN: account $ACCT is marked limited — starting anyway (you asked for it; auto would skip it)" >&2
  fi
  if [ "$ACCT" != a ] && [ "$COS_OS" != mac ]; then
    echo "addon accounts: macOS only, skipping (account $ACCT → a)" >&2; ACCT=a
  fi
  if [ "$ACCT" != a ] && ! security find-generic-password -s "cos-claude-account-$ACCT" >/dev/null 2>&1; then
    echo "refuse: no Keychain item cos-claude-account-$ACCT for account '$ACCT'." >&2
    echo "  The owner runs once: $HERE/addons/account-add.sh $ACCT   (browser sign-in as that account; token captured, never shown)" >&2; exit 2
  fi
fi

# Continuation — resolve the predecessor's transcript by its custom title (the claude -n name).
find_pred() {   # newest transcript whose custom title is exactly $1, across --dir + every launch dir
  local d slug pd f
  { IFS=: read -r -a _pd <<< "$DIR:${COS_LAUNCH_DIRS:-}"
    for d in "${_pd[@]}"; do
      [ -n "$d" ] || continue
      slug=$(printf '%s' "${d%/}" | tr '/.' '--'); pd="$HOME/.claude/projects/$slug"; [ -d "$pd" ] || continue
      LC_ALL=C command grep -l -F "\"customTitle\":\"$1\"" "$pd"/*.jsonl 2>/dev/null || true
    done; } | sort -u | while IFS= read -r f; do printf '%s\t%s\n' "$(cos_mtime "$f")" "$f"; done | sort -rn | head -1 | cut -f2-
}
# Session file first — prints "<current|stale|none>\t<why>\t<path>". Rule in the header.
find_sess() {
  cos_python - "$1" "$COS_DIR" "$DIR" "${COS_VAULT:-}" "${COS_MONOREPO:-}" "${COS_LAUNCH_DIRS:-}" <<'PYS'
import os, re, sys, time
old, cos, d, vault, mono, launch = sys.argv[1:]
roots = [r for r in [vault, mono, d, *launch.split(":")] if r]
def resolve(p):
    p = os.path.expanduser(p.strip().strip("`'\"").rstrip(".,)"))
    if os.path.isabs(p): return p if os.path.isfile(p) else None
    for r in roots:
        q = os.path.join(r, p)
        if os.path.isfile(q): return q
    return None
KEY = re.compile(r"session(?:[ _]file)?(?: written| reconstructed| updated)?\s*:\s*`?([^`;·|]*?\.md)\b", re.I)
NOOP = re.compile(r"noop|\bidle\b|no[ -]change|unchanged|nothing new", re.I)
STAMP = re.compile(r"^status:\s*\S+\s+(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2})")
# live first, then _archive/ (archive.sh moves finished/parked workers' files there — still resumable)
cands = [os.path.join(cos, *p) for p in (("tasks", old + ".md"), ("inbox", old + ".md"), ("_archive", "tasks", old + ".md"), ("_archive", "inbox", old + ".md"))]
inbox = next((c for c in cands if os.path.isfile(c)), cands[1])
text = open(inbox, encoding="utf-8", errors="replace").read() if os.path.isfile(inbox) else ""
if inbox.endswith(".md") and "/tasks/" in inbox and "\n## Reports" in text: text = text[text.index("\n## Reports") + 1:]
lines = text.split("\n")
cand, idx, src, named = None, None, None, None
for i in range(len(lines) - 1, -1, -1):
    m = KEY.search(lines[i])
    if m:
        named = named or m.group(1).strip()
        f = resolve(m.group(1))
        if f: cand, idx, src = f, i, f"inbox/{old}.md line {i+1}"; break
if not cand:
    mp = next((c for c in [os.path.join(cos, *p) for p in (("tasks", old + ".md"), ("missions", old + ".yaml"), ("_archive", "tasks", old + ".md"), ("_archive", "missions", old + ".yaml"))] if os.path.isfile(c)), "")
    if os.path.isfile(mp):
        for l in open(mp, encoding="utf-8", errors="replace"):
            m = re.match(r"\s*(?:session_file|session file|session_link|handoff)\s*:\s*\"?([^\"#]*?\.md)\"?\s*$", l)
            if m and resolve(m.group(1)): cand, src = resolve(m.group(1)), f"missions/{old}.yaml"
if not cand:
    why = f"session file named ({named}) but not on disk" if named else f"no session line in inbox/{old}.md or missions/{old}.yaml"
    print(f"none\t{why}\t"); sys.exit()
real = [(i, l) for i, l in enumerate(lines) if l.startswith("status:") and not NOOP.search(l)]
after = [(i, l) for i, l in real if idx is None or i > idx]
if not after:
    print(f"current\tfrom {src}; no real-work status line after it (only noop/idle)\t{cand}"); sys.exit()
i, l = after[-1]; m = STAMP.match(l)
if not m:
    print(f"stale\tfrom {src}; real work at inbox line {i+1} after it, stamp unparseable\t{cand}"); sys.exit()
ts = time.mktime(time.strptime(m.group(1).replace("T", " "), "%Y-%m-%d %H:%M"))
mt = os.path.getmtime(cand); fm = time.strftime("%Y-%m-%d %H:%M", time.localtime(mt))
if mt >= ts: print(f"current\tfrom {src}; file mtime {fm} >= newest real-work line {m.group(1)}\t{cand}")
else: print(f"stale\tfrom {src}; real work at {m.group(1)} (inbox line {i+1}) after file mtime {fm}\t{cand}")
PYS
}
if [ -n "$CONT" ]; then
  [[ "$CONT" =~ ^[a-z](-[a-z0-9]+){1,3}$ ]] || { echo "bad --continues '$CONT' — a worker name" >&2; exit 2; }
  [ "$CONT" != "$NAME" ] || { echo "refuse: --continues names this worker itself — give the successor a new name (e.g. $NAME-2)" >&2; exit 2; }
  [ "$REMOTE" = 0 ] || { echo "refuse: --continues is local only — the remote runner cannot read this machine's transcript" >&2; exit 2; }
  IFS=$'\t' read -r SSTATE SWHY PSESS <<< "$(find_sess "$CONT")"
  if [ "$SSTATE" = current ]; then
    CONT_WHY="session file (current) — $SWHY"
  else
    PRED=$(find_pred "$CONT")
    if [ -n "$PRED" ]; then CONT_WHY="transcript — $SWHY"; PSESS=
    elif [ "$SSTATE" = stale ]; then CONT_WHY="session file (STALE, no transcript found) — $SWHY"
      echo "WARN: no transcript for $CONT — using the stale session file; the worker must reconcile git carefully" >&2
    else echo "refuse: no current session file ($SWHY) and no transcript with \"customTitle\":\"$CONT\" under ~/.claude/projects/<launch-dir slug>/ — check the old worker's exact name (sessions.sh, LEDGER)" >&2; exit 2; fi
  fi
fi

# Load gate — local only (the remote has its own session cap).
if [ "$REMOTE" = 0 ]; then
  LOAD=$("$HERE/load-check.sh" 2>/dev/null | head -1 || true)
  case "$LOAD" in
    OFFLOAD*)
      if [ "$LIGHT" = 1 ]; then echo "WARN: $LOAD — starting anyway (--light: read-only worker)" >&2
      elif [ "$FORCE" = 1 ]; then echo "WARN: $LOAD — starting anyway (--force)" >&2
      else echo "refuse: $LOAD. Use --remote, queue it, --light for a read-only worker, or --force." >&2; exit 3; fi;;
    LOCAL_LIGHT*) [ "$LIGHT" = 1 ] || echo "WARN: $LOAD — only read-only work belongs here now" >&2;;
  esac
fi

# Goal gate — every worker has its own task goal; a GOALS.md goal is its parent.
GOALS="${COS_GOALS:-$COS_DIR/GOALS.md}"
hdr() { sed -nE "s/^[-*[:space:]]*\**$1\**:\**[[:space:]]*(.*)$/\1/p" "$CHARTER" | head -1 | sed -E 's/[[:space:]]+$//'; }
TGOAL=$(hdr '[Tt]ask [Gg]oal')
TDONE=$(hdr '[Dd]one [Mm]eans')
TINTENT=$(hdr '[Ii]ntent')
[ -n "$STORYLIST" ] || STORYLIST=$(hdr '[Ss]tory[ _][Ll]ist' | sed -E 's/^`(.*)`$/\1/')
GOAL=$(hdr '[Pp]arent [Gg]oal' | grep -oE '^[A-Za-z0-9]+' || true)
[ -n "$GOAL" ] || GOAL=$(hdr '[Gg]oal' | grep -oE '^[A-Za-z0-9]+' || true)   # legacy `goal: <ID>`
if [ -z "$TGOAL" ]; then
  echo "refuse: charter $CHARTER has no non-empty 'task goal:' line — one sentence, the outcome THIS task delivers" >&2
  echo "  (the owner's words where given). Header block: references/orchestration.md → Charter template." >&2; exit 2
fi
if [ -z "$GOAL" ]; then
  echo "refuse: charter $CHARTER has no 'parent goal: <ID>' line (legacy 'goal: <ID>' also accepted)." >&2
  echo "  IDs are the '### <ID> · ' headings in $GOALS. Serving none: write 'parent goal: none' and pass --no-goal." >&2; exit 2
fi
[ -n "$TDONE" ] || { echo "WARN: charter has no 'done means:' line — the worker gets no concrete finish check" >&2; TDONE="—"; }
# short slug of the task goal for inbox tags: first 4 content words, hyphen-joined
TSLUG=$(printf '%s' "$TGOAL" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' ' ' | tr ' ' '\n' \
  | grep -vxE '(a|an|the|and|or|of|to|for|in|on|at|by|from|with|his|her|own|so|can|every|all|it|its|is|are|be|that|this|through|via|them|they)?' \
  | head -4 | paste -sd- - || true)
[ -n "$TSLUG" ] || TSLUG="${NAME#*-}"
TG60="$TGOAL"; [ "${#TG60}" -le 60 ] || TG60="${TG60:0:59}…"
if [ "$GOAL" = none ]; then
  [ "$NOGOAL" = 1 ] || { echo "refuse: charter says 'parent goal: none' — pass --no-goal to spawn anyway (LEDGER marks it PARK risk)" >&2; exit 2; }
  GTAG="none·PARK-risk"; ITAG="[none] $TSLUG"
  PARENT_PROMPT="Parent goal: NONE from GOALS.md (spawned with --no-goal — PARK risk)."
else
  [ "$NOGOAL" = 0 ] || echo "WARN: --no-goal ignored — charter names parent goal $GOAL" >&2
  [ -f "$GOALS" ] || { echo "refuse: goals file $GOALS not found" >&2; exit 2; }
  GINFO=$(cos_python - "$GOALS" "$GOAL" <<'PY2'
import sys, re
path, gid = sys.argv[1:]
head = f"### {gid} · "
out, on = {}, False
for line in open(path, encoding="utf-8").read().split("\n"):
    if line.startswith(head):
        on = True; out["outcome"] = line[len(head):].strip(); continue
    if on and line.startswith("#"): break
    if on:
        m = re.match(r"^(intent|done means|status):\s*(.*)", line)
        if m and m.group(1) not in out: out[m.group(1)] = m.group(2).strip()
if not on: sys.exit(1)
for k in ("outcome", "intent", "done means", "status"): print(out.get(k) or "—")
PY2
) || { echo "refuse: parent goal '$GOAL' is not a '### $GOAL · ' heading in $GOALS" >&2; exit 2; }
  { read -r G_OUT; read -r G_INT; read -r G_DONE; read -r G_ST; } <<< "$GINFO"
  case "$G_ST" in parked*) echo "refuse: parent goal $GOAL is parked in $GOALS — un-park it, or use 'parent goal: none' + --no-goal" >&2; exit 2;; esac
  GTAG="$GOAL"; case "$G_ST" in confirmed*) ;; *) GTAG="$GOAL?";; esac
  ITAG="[$GOAL] $TSLUG"
  PARENT_PROMPT="Parent goal: $GOAL · $G_OUT (status: $G_ST). Intent: ${TINTENT:-$G_INT}."
fi
GOAL_PROMPT="YOUR TASK GOAL: ${TGOAL%.}. Done means: ${TDONE%.}. $PARENT_PROMPT Off-goal rule: if the next step doesn't serve your TASK goal, report BLOCKED off-goal in your inbox instead of doing it. Tag every inbox status line with '$ITAG', e.g. 'status: WORKING <YYYY-MM-DD HH:MM> $ITAG'."

STAMP=$(date '+%Y-%m-%d %H:%M')
# One task file is the charter, the inbox, the mission and the LEDGER row.
TASKP="$COS_DIR/tasks/$NAME.md"
[ -z "$RESUME" ] || TASKP="$TASKP_RESUME"   # resume updates the given task file, never re-stamps it
DEST_CHARTER="$TASKP"
INBOX="$TASKP"
MISSION="$TASKP"
# argv-safe (devault'd) copies — only for text that lands in a CMD string or the worker's prompt.
# Real vars above still point at the actual vault paths for every file-system operation.
DIR_SAFE="$(devault "$DIR")"
DEST_CHARTER_SAFE="$(devault "$DEST_CHARTER")"
INBOX_SAFE="$(devault "$INBOX")"
MISSION_SAFE="$(devault "$MISSION")"
# Mission file — the machine-readable plan (schema 1). One build slice when a story list is linked.
write_mission() {
  cos_python - "$1" "$NAME" "$TGOAL" "$TDONE" "$GOAL" "$STORYLIST" "$ACCT" "$CONT" "$PRED" "$PSESS" "${DEPS[@]+"${DEPS[@]}"}" <<'PY3'
import json, sys, datetime as dt
out, name, tg, td, goal, sl, acct, cont, pred, psess, *deps = sys.argv[1:]
q = json.dumps
L = ["# Mission file — chief-of-staff schema 1 (references/orchestration.md → Mission file).",
     "# Written by spawn.sh from the charter header. next.sh reads it every 20 min → NEXT.md. Edit slices as the plan changes.",
     "schema: 1", f"worker: {name}", f"task_goal: {q(tg, ensure_ascii=False)}", f"done_means: {q(td, ensure_ascii=False)}",
     f"parent_goal: {goal}", f"account: {acct}              # Claude login id (a = default Keychain login); never a token",
     *([f"continues: {cont}"] if cont else []),
     *([f"predecessor_session: {json.dumps(psess)}"] if cont and psess else []),
     *([f"predecessor_transcript: {json.dumps(pred)}"] if cont and pred else []),
     "status: active            # active | done | parked | stopped",
     f"charter: charters/{name}.md", f"inbox: inbox/{name}.md", "heartbeat_min: 60", f"created: {dt.date.today()}",
     "depends_on_missions: [" + ", ".join(deps) + "]",
     "# asks: → block list, appended by the worker to ask the owner (class TEST|DECIDE|APPROVE); next.sh shows open ones",
     "#   as 'Needs you' at the top of NEXT.md. Schema: references/orchestration.md → Asks.", "slices:"]
if sl:
    L += ["  - id: build", "    title: stories code-complete", "    status: active", f"    owner: {name}", "    depends_on: []",
          f"    story_list: {q(sl)}"]
else:
    L += ["  - id: task", "    title: task goal met (done means)", "    status: active", f"    owner: {name}", "    depends_on: []"]
open(out, "w", encoding="utf-8").write("\n".join(L) + "\n")
PY3
}
NEWM=0; [ -f "$TASKP" ] || NEWM=1
# Task file: create it from the charter (legacy --charter), or take the given/queued one; then stamp the spawn fields.
write_task() {   # write_task FILE — FILE ends up a complete task file for this spawn (status claimed until launched)
  local f="$1"
  if [ -n "$TASKF" ] && ! [ "$TASKF" -ef "$f" ]; then cp "$TASKF" "$f"
  elif [ -z "$TASKF" ] && ! [ -f "$f" ]; then cos_python "$TPY" new "$f" --name "$NAME" --to "${NAME%%-*}" --from "${COS_FROM:-chief}" --status claimed --charter "$CHARTER"; fi
  local deps="[$(IFS=,; echo "${DEPS[*]+"${DEPS[*]}"}" | sed 's/,/, /g')]"
  cos_python "$TPY" set "$f" to "${NAME%%-*}" parent_goal "$GOAL" task_goal "$TGOAL" done_means "$TDONE" model "$MODEL" dir "$DIR" \
    account "$ACCT" depends_on_missions "$deps" heartbeat_min "${COS_HEARTBEAT_MIN:-60}" status claimed
  [ -z "$AGENT" ] || cos_python "$TPY" set "$f" agent "$AGENT"
  [ -z "$STORYLIST" ] || cos_python "$TPY" set "$f" story_list "$STORYLIST"
  [ -z "$CONT" ] || cos_python "$TPY" set "$f" continues "$CONT"
  [ -z "$CONT" ] || [ -z "$PSESS" ] || cos_python "$TPY" set "$f" predecessor_session "$PSESS"
  [ -z "$CONT" ] || [ -z "$PRED" ] || cos_python "$TPY" set "$f" predecessor_transcript "$PRED"
}
if [ "$DRY" = 0 ] && [ -z "$RESUME" ]; then mkdir -p "$COS_DIR/tasks"; write_task "$TASKP"; fi
# Set top-level keys in a mission file (replace in place, else insert after parent_goal:). Values are JSON-quoted
# when they hold spaces, slashes or YAML-special characters, so next.sh's YAML subset reads them.
mset() {
  cos_python - "$@" <<'PY4'
import sys, re, json
p, *kv = sys.argv[1:]
L = open(p, encoding="utf-8").read().split("\n")
for k, v in zip(kv[::2], kv[1::2]):
    v = json.dumps(v, ensure_ascii=False) if re.search(r"[\s/#:\"']", v) else v
    i = next((n for n, l in enumerate(L) if re.match(rf"{re.escape(k)}:", l)), None)
    if i is not None: L[i] = f"{k}: {v}"
    else:
        j = next((n for n, l in enumerate(L) if re.match(r"parent_goal:", l)), 0)
        L.insert(j + 1, f"{k}: {v}")
open(p, "w", encoding="utf-8").write("\n".join(L))
PY4
}

dry_goal() {
  echo "DRY-RUN task goal: $TGOAL"
  echo "DRY-RUN done means: $TDONE"
  echo "DRY-RUN parent: [$GTAG] · inbox tag: $ITAG · ledger: [$GTAG] $TG60"
  [ -z "$CONT" ] || { echo "DRY-RUN continues: $CONT · FIRST STEP path = $CONT_WHY"
    echo "DRY-RUN predecessor session file: ${PSESS:-none} · predecessor transcript: ${PRED:-none (not mined)}"
    echo "DRY-RUN after spawn: missions/$CONT.yaml → status: stopped, handoff: \"superseded by $NAME\"$([ -f "$COS_DIR/missions/$CONT.yaml" ] || echo ' (no such mission file — skipped)')"; }
  echo "DRY-RUN account: $ACCT$([ "$ACCT" = a ] && echo ' (default Keychain login)')$([ "$ACCT" != a ] && [ "$ACCT" != remote ] && echo " (Keychain item cos-claude-account-$ACCT, read at launch)")"
  echo "DRY-RUN prompt goal block: $GOAL_PROMPT"
  T=$(mktemp -d)/$NAME.md; [ ! -f "$TASKP" ] || cp "$TASKP" "$T"; write_task "$T"
  echo "DRY-RUN task file $TASKP$([ "$NEWM" = 0 ] && echo ' (exists — fields re-stamped)'):"; awk 'NR==1 || !/^---$/ {print} /^---$/ && NR>1 {print; exit}' "$T" | sed 's/^/  /'; rm -f "$T"
}
TAIL_PROMPT="Only when your whole task is finished (you report DONE, or the owner signs off or says stop) — never mid-task — run /agent-ops:session-update to write or update your session file (what changed, where it lives, how to resume) and put its path in your report line."
TEARDOWN_PROMPT="TEARDOWN at DONE: before your DONE report, stop every dev server/background process you started; for EVERY git worktree you created: make sure its branch is committed + pushed (or merged), then \`git worktree remove <path>\` (no --force; dirty → report it, never force); KEEP all branches; run \`git worktree prune\` in each repo you touched. Put a line in your report: \`teardown: N worktrees removed, M kept (why)\` — stop.sh refuses DONE without it."
STYLE_PROMPT="Style: concise. Report lines are one line each: verdict, evidence, what is next. No recaps, no filler. Never print secrets (keys, tokens, passwords) in tool output or reports."
# Opt-in standing rules (time-awareness, test tiers, subagent budgets, …): set COS_WORKER_PROMPT_EXTRA — examples in references/worker-prompt-examples.md.
# comma-joined (one argv, no glob); COS_WORKER_DISALLOWED_TOOLS (comma or space separated), empty = none
WORKER_DISALLOWED=$(printf '%s' "${COS_WORKER_DISALLOWED_TOOLS:-}" | tr -s ' ' ',')
DISALLOW_FLAG=; [ -z "$WORKER_DISALLOWED" ] || DISALLOW_FLAG="--disallowedTools $(printf '%q' "$WORKER_DISALLOWED") "
EXTRA_FLAGS="${COS_WORKER_CLAUDE_FLAGS:-}"; [ -z "$EXTRA_FLAGS" ] || EXTRA_FLAGS="$EXTRA_FLAGS "
CLAUDE_BIN="${COS_CLAUDE_BIN:-claude}"
EXTRA_PROMPT="${COS_WORKER_PROMPT_EXTRA:-}"; [ -z "$EXTRA_PROMPT" ] || EXTRA_PROMPT="$EXTRA_PROMPT "

# Pane colour (cmux add-on): task `color:` override, else COS_PANE_COLORS goal-prefix map (addons/lib/pane-color.sh).
PCOLOR=
if [ "$REMOTE" = 0 ] && [ "$COS_LAUNCHER" = cmux ]; then . "$HERE/addons/lib/pane-color.sh"; PCOLOR=$(cos_pane_color "$GOAL" "$TCOLOR_OVR"); fi

if [ "$REMOTE" = 0 ]; then
  LAUNCH="$LAUNCH_DIR/$NAME.sh"
  CMD="cd $(printf '%q' "$DIR_SAFE") && bash $(printf '%q' "$LAUNCH"); exec \"\$SHELL\" -l"
  ASK_PROMPT="To ask the owner anything (TEST / DECIDE / APPROVE), append an item to the asks: block in the frontmatter of your task file (format: references/orchestration.md → Asks) and name it in a report line; check the charter's Pre-authorized list first — those need no ask. Never edit any other frontmatter key."
  CONT_PROMPT=
  if [ -n "$CONT" ] && [ -z "$PRED" ]; then
    CONT_PROMPT="MANDATORY FIRST STEP — you continue worker $CONT. Before any build: read its session file $(devault "$PSESS") (the Resume Here block first); reconcile with git in every repo it names; post one report line; only then continue. Do NOT mine the old transcript — $([ "$SSTATE" = current ] && echo 'the session file is current' || echo 'none was found; the session file is STALE, so treat git as the truth where they differ'). "
  elif [ -n "$CONT" ]; then
    CONT_PROMPT="MANDATORY FIRST STEP — you continue worker $CONT. Before any build: have a sonnet subagent run /agent-ops:session-from-transcript on the old transcript $PRED to write a session file with a Resume Here block; re-read it; reconcile with git in every repo; post one report line; only then continue. "
  fi
  # Resume: no first prompt — the session already has it; same flags otherwise (cache = model+effort+flags+account).
  LAST_ARGS="--resume $RESUME"
  [ -n "$RESUME" ] || PROMPT="$STYLE_PROMPT ${EXTRA_PROMPT}You are a worker session spawned by the chief of staff. ${CONT_PROMPT}Your task file: $DEST_CHARTER_SAFE — its body is your charter; do it. Report ONLY by appending lines under \`## Reports\` at the end of that same file (format in the charter → Report protocol). Plain text in this terminal never reaches the chief. $GOAL_PROMPT $ASK_PROMPT $TEARDOWN_PROMPT $TAIL_PROMPT"
  [ -n "$RESUME" ] || LAST_ARGS=$(printf '%q' "$PROMPT")
  RC_FLAG=; [ "${COS_REMOTE_CONTROL:-0}" = 1 ] && [ "$ACCT" = a ] && RC_FLAG="--remote-control "
  ACCT_LINES="# account a: the default Claude login"
  if [ "$ACCT" != a ]; then
    RC_FLAG=   # Remote Control refuses long-lived (inference-only) tokens
    ACCT_LINES="# account $ACCT: token read from Keychain item cos-claude-account-$ACCT at launch (never stored here)
T=\$(/usr/bin/security find-generic-password -s cos-claude-account-$ACCT -w 2>/dev/null) && [ -n \"\$T\" ] || { echo \"no Keychain item cos-claude-account-$ACCT — run addons/account-add.sh $ACCT\"; exit 2; }
export CLAUDE_CODE_OAUTH_TOKEN=\"\$T\"; unset T
export COS_CLAUDE_ACCOUNT_ID=$ACCT"
  fi
  CMUX_LINES=
  if [ "$COS_LAUNCHER" = cmux ]; then
    CM="${COS_CMUX_BIN:-cmux}"
    CMUX_LINES=$(cat <<L
# cmux status: the hook settings cmux's own claude wrapper injects, handed to the real binary
unset CMUX_CLAUDE_PID CMUX_AGENT_LAUNCH_KIND CMUX_AGENT_LAUNCH_EXECUTABLE CMUX_AGENT_LAUNCH_CWD CMUX_AGENT_LAUNCH_ARGV_B64 CMUX_AGENT_RESUME_LAUNCH CMUX_AGENT_RESTORE_LAUNCH
COS_CMUX_CLI="\${CMUX_BUNDLED_CLI_PATH:-$(printf '%q' "$CM")}"; COS_CMUX_HOOKS=$(printf '%q' "$LAUNCH_DIR/$NAME.cmux-hooks.json")
if [ -n "\${CMUX_SURFACE_ID:-}" ] && [ "\${CMUX_CLAUDE_HOOKS_DISABLED:-}" != 1 ] && command -v "\$COS_CMUX_CLI" >/dev/null 2>&1 \\
   && ( umask 077; CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=2 "\$COS_CMUX_CLI" hooks claude inject-settings </dev/null >"\$COS_CMUX_HOOKS" 2>/dev/null ) \\
   && $(printf '%q' "$COS_PYTHON") -c 'import json,sys; h=json.load(open(sys.argv[1])).get("hooks"); sys.exit(0 if isinstance(h,dict) and h else 1)' "\$COS_CMUX_HOOKS" 2>/dev/null; then
  export CMUX_CLAUDE_PID=\$\$ CMUX_CLAUDE_HOOK_CMUX_BIN="\$COS_CMUX_CLI"
  COS_CMUX_ARGS=(--settings "\$COS_CMUX_HOOKS")
else
  rm -f "\$COS_CMUX_HOOKS"
fi
L
)
  fi
  LAUNCH_BODY=$(cat <<L
#!/usr/bin/env bash
for v in \$(env | grep -iE "^(CLAUDE|AI_AGENT)" | cut -d= -f1); do unset "\$v"; done
cd $(printf '%q' "$DIR") || { echo $(printf '%q' "cd failed: $DIR"); exit 2; }
COS_CMUX_ARGS=()
$CMUX_LINES
$ACCT_LINES
# worker hooks: cos-heartbeat touches the heartbeat file, cos-ck answers the check-in ping
export COS_WORKER=$NAME COS_TAG=$(printf '%q' "$ITAG") COS_REPORT_FILE=$(printf '%q' "$INBOX_SAFE") COS_HEARTBEAT_DIR=$(printf '%q' "$(devault "$COS_DIR")/.heartbeat")
exec $(printf '%q' "$CLAUDE_BIN") "\${COS_CMUX_ARGS[@]+"\${COS_CMUX_ARGS[@]}"}" ${RC_FLAG}-n $(printf '%q' "$NAME") --model $MODEL ${AGENT_FLAG}--effort high ${DISALLOW_FLAG}${EXTRA_FLAGS}$LAST_ARGS
L
)
  WS=
  if [ "$COS_LAUNCHER" = cmux ]; then
    command -v "$CM" >/dev/null 2>&1 || [ -x "$CM" ] || { echo "cmux not found (COS_LAUNCHER=cmux) — set COS_LAUNCHER=tmux or print" >&2; exit 1; }
    # Target workspace, first hit wins: --workspace / $COS_SPAWN_WORKSPACE, the config pin if it still exists,
    # the workspace titled $COS_CMUX_WORKSPACE_TITLE (default "chief").
    TREE=$("$CM" tree --all 2>/dev/null || true)
    ws_live() { [ -z "$TREE" ] || printf '%s\n' "$TREE" | awk -v w="$1" '/ workspace workspace:[0-9]+ / {for(i=1;i<=NF;i++) if ($i==w) f=1} END {exit !f}'; }
    WS="$WS_ARG"
    if [ -n "$WS" ]; then
      ws_live "$WS" || { echo "refuse: --workspace $WS is not in \`cmux tree --all\` — pass a live workspace:N ref" >&2; exit 2; }
    elif [ -n "${COS_CMUX_WORKSPACE:-}" ]; then
      if ws_live "$COS_CMUX_WORKSPACE"; then WS="$COS_CMUX_WORKSPACE"
      else echo "WARN: COS_CMUX_WORKSPACE=$COS_CMUX_WORKSPACE is stale — falling back to the workspace titled \"${COS_CMUX_WORKSPACE_TITLE:-chief}\"" >&2; fi
    fi
    [ -n "$WS" ] || WS=$(printf '%s\n' "$TREE" | awk -v t="${COS_CMUX_WORKSPACE_TITLE:-chief}" '$0 ~ (" workspace workspace:[0-9]+ \"" t "\"( |$)") {for(i=1;i<=NF;i++) if ($i ~ /^workspace:[0-9]+$/) {print $i; exit}}')
  fi
  wt_shell_args() {   # one arg per line: the shell Windows Terminal opens for this worker (launch script, then a login shell)
    if [ "${COS_WSL:-0}" = 1 ]; then printf '%s\n' wsl.exe -d "${WSL_DISTRO_NAME:-}" -- bash -lc "bash $(printf '%q' "$LAUNCH") || true && exec bash -l"
    else printf '%s\n' "$( (cygpath -w "$(command -v bash)" 2>/dev/null) || command -v bash)" -lc "bash $(printf '%q' "$LAUNCH") || true && exec bash -l"; fi
  }
  TMUX_SESSION="${COS_TMUX_SESSION:-agent-ops}"
  if [ "$DRY" = 1 ]; then
    if [ -n "$RESUME" ]; then
      echo "DRY-RUN resume: session $RESUME · transcript $RTRANS"
      echo "DRY-RUN resume: model $MODEL ($MODEL_SRC) · effort high · account $ACCT$([ -n "${TACCT:-}" ] && echo " (task: $TACCT)") · agent ${AGENT:-none} · no first prompt"
    else dry_goal; fi
    case "$COS_LAUNCHER" in
      cmux)
        if [ -n "$WS" ]; then . "$HERE/addons/lib/cmux-equalize.sh"; GRID_PLAN=; [ "${COS_LAYOUT:-row}" = grid ] && GRID_PLAN=$(cos_grid_plan "$WS")
          if [ -n "$GRID_PLAN" ]; then printf 'DRY-RUN: %q new-split %s --surface %s --workspace %q --command %q --focus false\n' "$CM" "${GRID_PLAN#* }" "${GRID_PLAN% *}" "$WS" "$CMD"
          else printf 'DRY-RUN: %q new-pane --type terminal --workspace %q --direction right --command %q --focus false\n' "$CM" "$WS" "$CMD"; fi
        else printf 'DRY-RUN (no chief workspace, fallback): %q workspace create --name %q --cwd %q --command %q --focus false\n' "$CM" "$NAME" "$DIR" "$CMD"; fi
        [ -z "$PCOLOR" ] || printf 'DRY-RUN: then %q send %q to the new pane\n' "$CM" "/color $PCOLOR";;
      wt) printf 'DRY-RUN: %s -w 0 new-tab --title %q %s\n' "$(cos_wt_bin 2>/dev/null || echo wt.exe)" "$NAME" "$(wt_shell_args | tr '\n' ' ')";;
      tmux) printf 'DRY-RUN: tmux%s new-window -d -t %q -n %q -c %q %q\n' "${COS_TMUX_SOCKET:+ (socket $COS_TMUX_SOCKET)}" "$TMUX_SESSION" "$NAME" "$DIR" "$CMD";;
      *) printf 'DRY-RUN print launcher: run in a new terminal:\n  %s\n' "$CMD"
         echo "DRY-RUN claude command: $(printf '%s\n' "$LAUNCH_BODY" | grep '^exec ' | cut -c6-)";;
    esac
    echo "DRY-RUN task file: $TASKP"
    echo "DRY-RUN launch script $LAUNCH:"; printf '%s\n' "$LAUNCH_BODY" | sed 's/^/  /'
    exit 0
  fi
  mkdir -p "$LAUNCH_DIR"
  if [ -n "$RESUME" ]; then cos_python "$TPY" report "$TASKP" "status: RESUMED $STAMP session $RESUME (spawn.sh --resume: model $MODEL, effort high, account $ACCT)"
  else cos_python "$TPY" report "$TASKP" "status: STARTED $STAMP"; fi
  printf '%s\n' "$LAUNCH_BODY" > "$LAUNCH"
  chmod +x "$LAUNCH"
  case "$COS_LAUNCHER" in
    cmux)
      if [ -n "$WS" ]; then
        # Grid decided BEFORE the pane exists; never move a surface afterwards (that wipes scrollback).
        . "$HERE/addons/lib/cmux-equalize.sh"; GRID_PLAN=; [ "${COS_LAYOUT:-row}" = grid ] && GRID_PLAN=$(cos_grid_plan "$WS"); out=
        if [ -n "$GRID_PLAN" ]; then
          out=$("$CM" new-split "${GRID_PLAN#* }" --surface "${GRID_PLAN% *}" --workspace "$WS" --command "$CMD" --focus false 2>&1) \
            || { echo "WARN: new-split ${GRID_PLAN#* } of ${GRID_PLAN% *} failed ($out) — using new-pane default" >&2; out=; }
        fi
        printf '%s' "$out" | grep -qE 'surface:[0-9]+' \
          || out=$("$CM" new-pane --type terminal --workspace "$WS" --direction right --command "$CMD" --focus false)
        SURF=$(printf '%s\n' "$out" | grep -oE 'surface:[0-9]+' | head -1)
        [ -n "$SURF" ] || { echo "cmux new-pane gave no surface: $out" >&2; exit 1; }
        "$CM" tab-action --action rename --workspace "$WS" --surface "$SURF" --title "$NAME" >/dev/null 2>&1 \
          || echo "WARN: could not rename tab $SURF to $NAME" >&2
        WHERE="cmux ws${WS#workspace:}/$SURF"
        [ -z "$PCOLOR" ] || cos_send_pane_color "$CM" "$WS" "$SURF" "$PCOLOR"
        cos_equalize "$WS"
      else
        echo "WARN: no cmux workspace titled \"${COS_CMUX_WORKSPACE_TITLE:-chief}\" — falling back to a NEW workspace" >&2
        "$CM" workspace create --name "$NAME" --cwd "$DIR" --command "$CMD" --focus false
        WHERE=cmux
      fi;;
    tmux)
      command -v tmux >/dev/null 2>&1 || { echo "tmux not found (COS_LAUNCHER=tmux) — install tmux or set COS_LAUNCHER=print" >&2; exit 1; }
      cos_tmux has-session -t "$TMUX_SESSION" 2>/dev/null || cos_tmux new-session -d -s "$TMUX_SESSION" -n chief
      cos_tmux new-window -d -t "$TMUX_SESSION" -n "$NAME" -c "$DIR" "$CMD"
      WHERE="tmux $TMUX_SESSION:$NAME";;
    wt)
      WTB=$(cos_wt_bin) || { echo "wt.exe not found (COS_LAUNCHER=wt) — install Windows Terminal or set COS_LAUNCHER=print" >&2; exit 1; }
      WTARGS=(); while IFS= read -r a; do WTARGS+=("$a"); done < <(wt_shell_args)
      "$WTB" -w 0 new-tab --title "$NAME" "${WTARGS[@]}" >/dev/null 2>&1 \
        || { echo "wt.exe new-tab failed — run it yourself: bash -l $LAUNCH" >&2; exit 1; }
      WHERE="wt $NAME";;
    *)
      echo "print launcher — open a terminal and run:"
      echo "  $CMD"
      echo "claude command (inside $LAUNCH): $(printf '%s\n' "$LAUNCH_BODY" | grep '^exec ' | cut -c6-)"
      echo "task file: $TASKP"
      WHERE="print (owner launches)";;
  esac
else
  # Remote runner add-on: host from COS_REMOTE_HOST, else hosts.<COS_REMOTE_HOST_KEY>.ip in the COS_INVENTORY yaml.
  if [ -n "${COS_REMOTE_HOST:-}" ]; then RHOST="$COS_REMOTE_HOST"
  elif [ -n "${COS_INVENTORY:-}" ] && [ -n "${COS_REMOTE_HOST_KEY:-}" ]; then
    RHOST=$(cos_python -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['hosts'][sys.argv[2]]['ip'])" "$COS_INVENTORY" "$COS_REMOTE_HOST_KEY") \
      || { echo "cannot resolve hosts.$COS_REMOTE_HOST_KEY.ip in $COS_INVENTORY" >&2; exit 1; }
  else echo "refuse: remote runner add-on not configured (COS_REMOTE_HOST unset)" >&2; exit 2; fi
  : "${COS_REMOTE_USER:?COS_REMOTE_USER unset — remote runner add-on not configured}"
  COS_REMOTE_HOST_KEY="${COS_REMOTE_HOST_KEY:-$RHOST}"; COS_REMOTE_MAX_SESSIONS="${COS_REMOTE_MAX_SESSIONS:-3}"
  DEST="$COS_REMOTE_USER@$RHOST"
  SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEST")
  RTMUX="${COS_REMOTE_TMUX_BIN:-tmux}"; RTSESS="${COS_REMOTE_TMUX_SESSION:-agent-ops}"
  RPROMPT="$STYLE_PROMPT ${EXTRA_PROMPT}You are a worker session spawned by the chief of staff. Read your charter at ~/cos/charters/$NAME.md — then do it. Report ONLY by writing to ~/cos/inbox/$NAME.md (the chief pulls it; paths in the charter that point at the host machine do not exist here). You run on the remote runner as user $COS_REMOTE_USER in ~/$RDIR — a repo seeded from the host with NO git credentials: never push; commit on a branch and report the branch. $GOAL_PROMPT $TAIL_PROMPT"
  RLAUNCH=$(cat <<L
#!/bin/bash
export PATH="\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
for v in \$(env | grep -iE "^(CLAUDECODE|CLAUDE_CODE_ENTRYPOINT|CMUX|AI_AGENT)" | cut -d= -f1); do unset "\$v"; done
cd "\$HOME"/$(printf '%q' "$RDIR") || { echo "cd failed: ~/$RDIR"; exit 2; }
exec claude -n $(printf '%q' "$NAME") --model $MODEL ${AGENT_FLAG}--effort high ${EXTRA_FLAGS}$(printf '%q' "$RPROMPT")
L
)
  RCHECK='d="$HOME/$2"; [ -d "$d" ] || { echo "nodir $d"; exit 0; }; echo "live $(pgrep -u "$USER" -x claude | wc -l | tr -d " ")"'
  RSETUP='mkdir -p ~/cos/charters ~/cos/inbox && cat > ~/cos/charters/"$1".launch.sh && chmod 700 ~/cos/charters/"$1".launch.sh && printf "# %s inbox\n\nstatus: STARTED %s\n\n" "$1" "$3" > ~/cos/inbox/"$1".md'
  RTX="$(printf '%q' "$RTMUX")${COS_REMOTE_TMUX_SOCKET:+ -S $(printf '%q' "$COS_REMOTE_TMUX_SOCKET")}"
  RTMUXCMD="$RTX has-session -t $(printf '%q' "$RTSESS") 2>/dev/null || $RTX new-session -d -s $(printf '%q' "$RTSESS"); $RTX"' new-window -d -t '"$(printf '%q' "$RTSESS")"' -n "$1" -c "$HOME/$2" "/bin/bash $HOME/cos/charters/$1.launch.sh; exec \$SHELL -l"'
  if [ "$DRY" = 1 ]; then
    dry_goal
    echo "DRY-RUN remote: $DEST  dir ~/$RDIR  (from --dir $DIR)  tmux session $RTSESS window $NAME"
    printf 'DRY-RUN: %s bash -c %q _ %q %q\n' "${SSH[*]}" "$RCHECK" "$NAME" "$RDIR"
    printf 'DRY-RUN: %s "cat > cos/charters/%s.md" < %q\n' "${SSH[*]}" "$NAME" "$CHARTER"
    printf 'DRY-RUN: %s bash -c %q _ %q %q %q  <<launch script>>\n' "${SSH[*]}" "$RSETUP" "$NAME" "$RDIR" "$STAMP"
    printf 'DRY-RUN: %s bash -c %q _ %q %q\n' "${SSH[*]}" "$RTMUXCMD" "$NAME" "$RDIR"
    echo "DRY-RUN launch script ~/cos/charters/$NAME.launch.sh:"; printf '%s\n' "$RLAUNCH" | sed 's/^/  /'
    exit 0
  fi
  rsh() { local body="$1"; shift; "${SSH[@]}" "bash -c $(printf '%q' "$body") _$(printf ' %q' "$@")"; }
  chk=$(rsh "$RCHECK" "$NAME" "$RDIR") || { echo "ssh $DEST failed — leave the task status: open; the queue retries next run" >&2; exit 1; }
  case "$chk" in
    nodir*) [ "$NEWM" = 0 ] || rm -f "$MISSION"; echo "refuse: remote dir ${chk#nodir } does not exist on $COS_REMOTE_HOST_KEY — seed it first (git push from this machine)" >&2; exit 2;;
    live*) live="${chk#live }";;
    *) echo "unexpected remote check output: $chk" >&2; exit 1;;
  esac
  [ "$live" -lt "$COS_REMOTE_MAX_SESSIONS" ] || { echo "remote full: $live/$COS_REMOTE_MAX_SESSIONS sessions" >&2; exit 3; }
  "${SSH[@]}" "mkdir -p ~/cos/charters && cat > ~/cos/charters/$NAME.md" < "$DEST_CHARTER"
  printf '%s\n' "$RLAUNCH" | rsh "$RSETUP" "$NAME" "$RDIR" "$STAMP"
  rsh "$RTMUXCMD" "$NAME" "$RDIR" || { echo "remote tmux new-window failed" >&2; exit 1; }
  WHERE="remote:$COS_REMOTE_HOST_KEY/tmux:$NAME"
fi

# LEDGER has an `account` column after `status`; 7-cell rows without it stay readable (account blank = a).
LEDGER="$COS_DIR/LEDGER.md"
if [ -f "$LEDGER" ] && grep -qxF '| started | name | where | model | task | charter | status |' "$LEDGER"; then
  cos_python - "$LEDGER" <<'PY5'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = s.replace("| started | name | where | model | task | charter | status |\n|---|---|---|---|---|---|---|",
              "| started | name | where | model | task | charter | status | account |\n|---|---|---|---|---|---|---|---|", 1)
open(p, "w", encoding="utf-8").write(s)
PY5
fi
# The task file is the ledger row (no LEDGER.md append).
if [ -n "$RESUME" ]; then cos_python "$TPY" set "$TASKP" status running where "$WHERE" resumed "$STAMP"
  echo "OK resumed $NAME session $RESUME ($WHERE, $MODEL, effort high, account $ACCT${AGENT:+, agent $AGENT}) — task file: $TASKP"; exit 0; fi
cos_python "$TPY" set "$TASKP" status running where "$WHERE" started "$STAMP" account "$ACCT" model "$MODEL"
[ "$REMOTE" = 0 ] || cos_python "$TPY" report "$TASKP" "status: STARTED $STAMP (remote — reports land in ~/cos/inbox/$NAME.md; collect.sh merges them here)"
# Predecessor superseded — only now that the successor is running.
if [ -n "$CONT" ]; then
  if [ -f "$COS_DIR/tasks/$CONT.md" ]; then cos_python "$TPY" set "$COS_DIR/tasks/$CONT.md" status stopped handoff "superseded by $NAME" closed "$STAMP"
    echo "task $CONT → status: stopped, handoff: superseded by $NAME" >&2
  elif [ -f "$COS_DIR/missions/$CONT.yaml" ]; then mset "$COS_DIR/missions/$CONT.yaml" status stopped handoff "superseded by $NAME"
    echo "mission $CONT → status: stopped, handoff: superseded by $NAME" >&2
  else echo "WARN: no missions/$CONT.yaml to mark superseded" >&2; fi
  "$HERE/sessions.sh" --tsv 2>/dev/null | awk -F'\t' -v n="$CONT" '$1=="live" && $2==n {f=1} END {exit !f}' \
    && echo "WARN: $CONT still has a live session — stop it (stop.sh $CONT) once $NAME has posted its first inbox line" >&2
fi
[ "$REMOTE" = 0 ] || INBOX="$DEST:~/cos/inbox/$NAME.md (collect.sh pulls it to $INBOX)"
echo "OK spawned $NAME ($WHERE, $MODEL, account $ACCT${AGENT:+, agent $AGENT}, parent [$GTAG]) — task goal: $TGOAL — task file: $TASKP"
