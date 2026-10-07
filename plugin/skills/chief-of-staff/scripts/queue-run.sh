#!/usr/bin/env bash
# The task queue. A queued task = tasks/<name>.md with `status: open` and `to: <machine prefix>`.
# Anyone (the owner, the chief on any machine, a worker) queues work by writing such a file; the sweep on the
# addressed machine picks it up. Called by next.sh (so a scheduler can run it with no Claude session alive),
# by addons/hermes-sweep.sh, and by SKILL.md SWEEP.
#   queue-run.sh [--dry-run] [--max N]      N = most spawns per run (default 2)
# Per open task addressed to THIS machine (`to:` = COS_MACHINE_PREFIX; the host also takes the remote prefix):
#   - `approved: false` (a one-way door the owner has not OK'd) → refused, stays open
#   - `needs:` holds `vault`, the secrets add-on is configured (COS_VAULT_PORT) and its /_health is not OK
#     → refused, stays open (add-on not configured → one skip line, not refused)
#   - else CLAIM BY RENAME (tasks/<n>.md → tasks/.<n>.md.claim-<pid>; only one process wins), stamp
#     status: claimed + claimed_by/claimed_at, rename back, run `spawn.sh --task-file`. spawn fails → status
#     back to open + queue_note with the exit code (load OFFLOAD = exit 3 → retried next run).
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
VAULT_OK=
vault_ok() {
  if [ -z "${COS_VAULT_PORT:-}" ]; then cos_skip "vault check" "secrets add-on not configured"; return 0; fi
  if [ -z "$VAULT_OK" ]; then
    VAULT_OK=no; curl -s -m 3 "http://127.0.0.1:${COS_VAULT_PORT}/_health" 2>/dev/null | grep -q '"ok": *true' && VAULT_OK=yes
  fi
  [ "$VAULT_OK" = yes ]
}
note() {   # note FILE REASON — record + print a refusal once per distinct reason
  local prev; prev=$(cos_python "$TPY" get "$1" queue_note)
  [ "${prev%% @*}" = "$2" ] && return 0
  [ "$DRY" = 1 ] || cos_python "$TPY" set "$1" queue_note "$2 @$(date '+%Y-%m-%d %H:%M')"
  echo "⏸ queue: $(basename "$1" .md) — $2"
}
n=0
while IFS=$'\t' read -r name st to path; do
  [ "$st" = open ] || continue
  case " $PFXS " in *" $to "*) ;; *) continue;; esac
  [ "$n" -lt "$MAX" ] || { echo "queue: more open tasks for $COS_PREFIX — next run" >&2; break; }
  appr=$(cos_python "$TPY" get "$path" approved)
  if [ "$appr" = false ]; then note "$path" "refused: approved: false (one-way door — the owner OKs it by setting approved: true)"; continue; fi
  needs=$(cos_python "$TPY" get "$path" needs)
  case "$needs" in *vault*) vault_ok || { note "$path" "refused: needs vault, secrets vault health not OK"; continue; };; esac
  if [ "$DRY" = 1 ]; then echo "DRY-RUN queue: would claim + spawn $name (to $to) → spawn.sh --task-file $path"; n=$((n+1)); continue; fi
  claim="$(dirname "$path")/.$(basename "$path").claim-$$"
  mv -n "$path" "$claim" 2>/dev/null && [ -f "$claim" ] && ! [ -e "$path" ] || { echo "queue: $name already claimed elsewhere" >&2; continue; }
  cos_python "$TPY" set "$claim" status claimed claimed_by "$COS_PREFIX:$$" claimed_at "$(date '+%Y-%m-%d %H:%M')"
  mv "$claim" "$path"
  n=$((n+1))
  if out=$("$HERE/spawn.sh" --task-file "$path" 2>&1); then
    echo "▶ queue: spawned $name — $(printf '%s' "$out" | tail -1 | cut -c1-160)"
  else
    rc=$?
    cos_python "$TPY" set "$path" status open queue_detail "$(printf '%s' "$out" | grep -m1 -E 'refuse|fail|error' | cut -c1-160)"
    note "$path" "spawn.sh exit $rc — back to open, retried next run$([ "$rc" = 3 ] && echo ' (load OFFLOAD)')"
  fi
done < <(cos_python "$TPY" list "$COS_DIR")
