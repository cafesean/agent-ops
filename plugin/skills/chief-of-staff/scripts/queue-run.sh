#!/usr/bin/env bash
# The task queue. A queued task = tasks/<name>.md with `status: open` and `to: <machine prefix>`.
# Anyone (the owner, the chief on any machine, a worker) queues work by writing such a file; the sweep on the
# addressed machine picks it up. Called by next.sh (so a scheduler can run it with no Claude session alive),
# by an external scheduler, and by SKILL.md SWEEP.
#   queue-run.sh [--dry-run] [--max N]      N = most spawns per run (default 2)
# Per open task addressed to THIS machine (`to:` = COS_MACHINE_PREFIX; the host also takes the remote prefix):
#   - `approved: false` (a one-way door the owner has not OK'd) → refused, stays open
#   - `needs:` is set and COS_NEEDS_CHECK_CMD (optional, a user-layer script) exits non-zero for it
#     (run as `$COS_NEEDS_CHECK_CMD <needs value>`) → refused, stays open (unset → one skip line, not refused)
#   - else CLAIM BY RENAME (tasks/<n>.md → tasks/.<n>.md.claim-<pid>; only one process wins), stamp
#     status: claimed + claimed_by/claimed_at, rename back, run `spawn.sh --task-file`. spawn fails → status
#     back to open + queue_note with the exit code (load OFFLOAD = exit 3 → retried next run; continuity ladder =
#     exit 6 → stays open, the chief resumes or messages the predecessor, or adds `--fresh-ok` by hand).
#   - `status: claimed` with no `where:` and claimed_at older than COS_CLAIM_STALE_MIN (15) min → reopened.
#   - never claimed: a task named in $COS_DIR/CHIEF (`<prefix>: <name>` lines) or whose session is live
#     (sessions.sh --tsv) → one stderr line, skipped.
#   - every reopen is compare-and-set (tasks.py set-if): only while status is still claimed by THIS run, so a task
#     set running meanwhile (spawn killed mid-way) is never flipped back to open.
# A refusal is printed only when its reason changes (queue_note in the task), so the 20-min cron pages once.
# stdout: one line per spawn / new refusal; nothing when nothing changed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cos-env.sh"
DRY=0 MAX=2
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY=1; shift;; --max) MAX="$2"; shift 2;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; done
TPY="$HERE/lib/tasks.py"
[ -d "$COS_DIR/tasks" ] || exit 0
PFXS="$COS_PREFIX"
[ "$COS_PREFIX" != "$COS_HOST_PREFIX" ] || [ -z "${COS_REMOTE_MACHINE_PREFIX:-}" ] || PFXS="$PFXS ${COS_REMOTE_MACHINE_PREFIX}"
needs_ok() {   # needs_ok VALUE → 0 when the task's needs are met (or no checker is configured)
  if [ -z "${COS_NEEDS_CHECK_CMD:-}" ]; then cos_skip "needs check" "COS_NEEDS_CHECK_CMD not set"; return 0; fi
  $COS_NEEDS_CHECK_CMD "$1" >/dev/null 2>&1
}
note() {   # note FILE REASON — record + print a refusal once per distinct reason
  local prev; prev=$(cos_python "$TPY" get "$1" queue_note)
  [ "${prev%% @*}" = "$2" ] && return 0
  [ "$DRY" = 1 ] || cos_python "$TPY" set "$1" queue_note "$2 @$(date '+%Y-%m-%d %H:%M')"
  echo "⏸ queue: $(basename "$1" .md) — $2"
}
n=0
GUARD=
guarded() {   # guarded NAME — the live chief (CHIEF `<prefix>: <name>` line) or a live session: never claim it
  if [ -z "$GUARD" ]; then
    GUARD=" $(sed -n 's/^[a-z][a-z]*:[[:space:]]*\([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p' "$COS_DIR/CHIEF" 2>/dev/null | xargs) $("$HERE/sessions.sh" --tsv 2>/dev/null | awk -F'\t' '$1 == "live" {print $2}' | xargs) "
  fi
  case "$GUARD" in *" $1 "*) return 0;; esac; return 1
}
stale_claim() {   # stale_claim FILE — claimed > COS_CLAIM_STALE_MIN (15) min ago and never launched (no where:)
  [ -z "$(cos_python "$TPY" get "$1" where)" ] || return 1
  local at; at=$(cos_python "$TPY" get "$1" claimed_at)
  cos_python - "$1" "$at" "${COS_CLAIM_STALE_MIN:-15}" <<'PYS'
import os, sys, time
f, at, lim = sys.argv[1], sys.argv[2], int(sys.argv[3])
try: t = time.mktime(time.strptime(at[:16], "%Y-%m-%d %H:%M"))
except Exception: t = os.path.getmtime(f)
sys.exit(0 if time.time() - t > lim * 60 else 1)
PYS
}
while IFS=$'\t' read -r name st to path; do
  case " $PFXS " in *" $to "*) ;; *) continue;; esac
  case "$st" in open|claimed) ;; *) continue;; esac
  if guarded "$name"; then echo "queue: skip $name — live chief/session (CHIEF or sessions.sh), status '$st' left as is" >&2; continue; fi
  if [ "$st" = claimed ] && stale_claim "$path"; then
    if [ "$DRY" = 1 ] || cos_python "$TPY" set-if "$path" --if status claimed --if where "" status open queue_detail "stale claim reopened @$(date '+%Y-%m-%d %H:%M')" 2>/dev/null; then
      echo "↺ queue: $name — stale claim (never launched) → open"; st=open
    fi
  fi
  [ "$st" = open ] || continue
  [ "$n" -lt "$MAX" ] || { echo "queue: more open tasks for $COS_PREFIX — next run" >&2; break; }
  appr=$(cos_python "$TPY" get "$path" approved)
  if [ "$appr" = false ]; then note "$path" "refused: approved: false (one-way door — the owner OKs it by setting approved: true)"; continue; fi
  needs=$(cos_python "$TPY" get "$path" needs)
  [ -z "$needs" ] || needs_ok "$needs" || { note "$path" "refused: needs ($needs) not met per COS_NEEDS_CHECK_CMD"; continue; }
  if [ "$DRY" = 1 ]; then echo "DRY-RUN queue: would claim + spawn $name (to $to) → spawn.sh --task-file $path"; n=$((n+1)); continue; fi
  claim="$(dirname "$path")/.$(basename "$path").claim-$$"
  mv -n "$path" "$claim" 2>/dev/null && [ -f "$claim" ] && ! [ -e "$path" ] || { echo "queue: $name already claimed elsewhere" >&2; continue; }
  cos_python "$TPY" set "$claim" status claimed claimed_by "$COS_PREFIX:$$" claimed_at "$(date '+%Y-%m-%d %H:%M')"
  mv "$claim" "$path"
  n=$((n+1))
  rc=0; out=$("$HERE/spawn.sh" --task-file "$path" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then
    echo "▶ queue: spawned $name — $(printf '%s' "$out" | tail -1 | cut -c1-160)"
  else
    # compare-and-set: reopen only while the claim is still ours — a task set running meanwhile stays running
    cos_python "$TPY" set-if "$path" --if status claimed --if claimed_by "$COS_PREFIX:$$" status open \
      queue_detail "$(printf '%s' "$out" | grep -m1 -E 'refuse|fail|error' | cut -c1-160)" 2>/dev/null \
      || { echo "queue: $name — spawn.sh exit $rc but status is now '$(cos_python "$TPY" get "$path" status)', not our claim: left as is" >&2; continue; }
    case "$rc" in
      3) why=' (load OFFLOAD)';;
      6) why=' (continuity ladder: resume or message the predecessor, or respawn with --fresh-ok)';;
      *) why=;;
    esac
    note "$path" "spawn.sh exit $rc — back to open, retried next run$why"
  fi
done < <(cos_python "$TPY" list "$COS_DIR")
