#!/usr/bin/env bash
# Tests for spawn.sh --resume / --resume-prompt, the resume idle gate, the continuity ladder (--continues / --fresh-ok),
# role pointer lines and COS_SPAWN_ENV_CMD — dry runs in a temp HOME + config with a fake claude.
# The printed launch script is the one file every launcher runs, so running it with a fake claude proves the argv
# and the environment the worker gets.
# Run: bash plugin/tests/spawn-resume.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SPAWN="$HERE/../skills/chief-of-staff/scripts/spawn.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/spawnresume.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

mkdir -p "$T/cos/tasks" "$T/repo" "$T/home/.claude/sessions" "$T/vault" "$T/bin"
U=0123abcd-0000-4000-8000-0000000000aa
SLUG=$(printf '%s' "$T/repo" | tr '/.' '--'); mkdir -p "$T/home/.claude/projects/$SLUG"
iso() { python3 -c 'import sys,datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"; }
transcript() {  # transcript UUID MIN_AGO [TITLE]
  local f="$T/home/.claude/projects/$SLUG/$1.jsonl" t; t=$(iso "$2")
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hi"}}\n{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-5-5","content":[]}}\n' "$t" "$t" > "$f"
  [ -z "${3:-}" ] || printf '{"type":"custom-title","customTitle":"%s"}\n' "$3" >> "$f"
}
transcript "$U" 5
printf 'COS_DIR=%q\nCOS_VAULT=%q\nCOS_VAULT_ALIAS=%q\nCOS_MACHINE_PREFIX=m\nCOS_HOST_PREFIX=m\nCOS_LAUNCH_DIRS=%q\nCOS_LAUNCHER=print\nCOS_CLAUDE_BIN=%q\n' \
  "$T/cos" "$T/vault" "$T/home/vault-alias" "$T/repo" "$T/bin/claude" > "$T/config.env"
# fake claude: one argv element per line, then the env keys it was given
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "$ARGV_OUT"\nenv > "$ARGV_OUT.env"\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"
TASK="$T/cos/tasks/m-docs-x.md"
cat > "$TASK" <<T2
---
name: m-docs-x
to: m
dir: $T/repo
model: opus
status: parked
---
- Task goal: answer the post.
- Done means: poster reacts.
- parent goal: none
T2
run() { HOME="$T/home" AGENT_OPS_CONFIG="$T/config.env" bash "$SPAWN" --dry-run --no-goal "$@" 2>&1; }
launch() { printf '%s\n' "$1" | sed -n '/^DRY-RUN launch script /,$p' | tail -n +2 | sed 's/^  //'; }
argv_of() { printf '%s\n' "$(launch "$1")" > "$T/launch.sh"; : > "$T/argv"
  env -i HOME="$T/home" PATH=/usr/bin:/bin ARGV_OUT="$T/argv" bash "$T/launch.sh" >/dev/null 2>&1; cat "$T/argv"; }

# 1. plain --resume: NO first prompt
out=$(run --task-file "$TASK" --force --resume "$U"); rc=$?
[ "$rc" = 0 ] && ok "plain --resume dry run exits 0" || bad "plain --resume dry run" "rc=$rc $out"
printf '%s\n' "$out" | grep -q 'no first prompt' && ok "plain --resume says no first prompt" || bad "no-first-prompt line" "$out"
a=$(argv_of "$out"); last2=$(printf '%s\n' "$a" | tail -2 | tr '\n' ' ')
[ "$last2" = "--resume $U " ] && ok "plain --resume: argv ends --resume UUID" || bad "plain argv tail" "$last2"

# 2. --resume-prompt: the exact text is claude's last argv element, after --resume UUID
P='New reply arrived. Run `$(ls -d ~/x/tool.sh | sort -V | tail -1) thread m-docs-x`, act on it; "park" again.'
out=$(run --task-file "$TASK" --force --resume "$U" --resume-prompt "$P"); rc=$?
[ "$rc" = 0 ] && ok "--resume-prompt dry run exits 0" || bad "--resume-prompt dry run" "rc=$rc $out"
printf '%s\n' "$out" | grep -qF 'first prompt (--resume-prompt): New reply' && ok "dry run names the first prompt" || bad "dry-run prompt line" "$out"
a=$(argv_of "$out")
[ "$(printf '%s\n' "$a" | tail -3 | head -2 | tr '\n' ' ')" = "--resume $U " ] && ok "--resume UUID kept before the prompt" || bad "resume order" "$a"
[ "$(printf '%s\n' "$a" | tail -1)" = "$P" ] && ok "prompt reaches claude byte-for-byte (no shell expansion)" || bad "prompt argv" "$(printf '%s\n' "$a" | tail -1)"

# 3. vault paths in the prompt go through the alias
out=$(run --task-file "$TASK" --force --resume "$U" --resume-prompt "read $T/vault/tasks/m-docs-x.md")
a=$(argv_of "$out"); l=$(printf '%s\n' "$a" | tail -1)
[ "$l" = "read $T/home/vault-alias/tasks/m-docs-x.md" ] && ok "vault path in prompt → alias" || bad "vault alias" "$l"

# 4. --resume-prompt alone is refused
out=$(run --task-file "$TASK" --force --resume-prompt "hi"); rc=$?
[ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'needs --resume' && ok "--resume-prompt without --resume → exit 2" || bad "refuse without --resume" "rc=$rc $out"

# 5. idle gate: last turn 90 min ago → exit 5; --force → WARN
transcript "$U" 90
out=$(HOME="$T/home" AGENT_OPS_CONFIG="$T/config.env" bash "$SPAWN" --task-file "$TASK" --dry-run --no-goal --resume "$U" 2>&1); rc=$?
[ "$rc" = 5 ] && ok "resume of a cold session → exit 5" || bad "idle gate" "rc=$rc $out"
out=$(run --task-file "$TASK" --force --resume "$U"); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'cache cold' && ok "--force passes the idle gate with a WARN" || bad "idle --force" "rc=$rc $out"

# 6. continuity ladder: predecessor's last turn 10 min ago → exit 6 with the resume command; --fresh-ok → WARN
P2=0123abcd-0000-4000-8000-0000000000bb
transcript "$P2" 10 m-docs-old
cat > "$T/cos/tasks/m-docs-old.md" <<T3
---
name: m-docs-old
to: m
dir: $T/repo
status: stopped
---
body
## Reports
status: STARTED 2026-01-01 10:00
T3
NEW="$T/cos/tasks/m-docs-new.md"
sed -e 's/^name: m-docs-x/name: m-docs-new/' -e 's/^status: parked/status: open/' "$TASK" > "$NEW"
out=$(run --task-file "$NEW" --continues m-docs-old); rc=$?
[ "$rc" = 6 ] && printf '%s\n' "$out" | grep -q -- "--resume $P2 --resume-prompt" && ok "warm predecessor → exit 6 with its --resume command" || bad "ladder rung 2" "rc=$rc $out"
out=$(run --task-file "$NEW" --continues m-docs-old --fresh-ok); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'fresh-ok' && ok "--fresh-ok spawns a fresh successor with a WARN" || bad "--fresh-ok" "rc=$rc $out"

# 7. same-topic WARN without --continues (a closed same-topic task < 50 min ago)
python3 - "$T/cos/tasks/m-docs-old.md" <<'PYC'
import sys, time
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("status: stopped\n", "status: stopped\nclosed: \"%s\"\n" % time.strftime("%Y-%m-%d %H:%M"), 1))
PYC
SAME="$T/cos/tasks/m-docs-old-2.md"
sed -e 's/^name: m-docs-new/name: m-docs-old-2/' "$NEW" > "$SAME"
out=$(run --task-file "$SAME"); rc=$?
printf '%s\n' "$out" | grep -q 'same-topic m-docs-old closed' && ok "same-topic closed task → WARN with its resume command" || bad "same-topic WARN" "rc=$rc $out"

# 8. role: no COS_BUILDER_DIRS → builder; pointer lines name worker-rules sections when the rulebook exists
printf '%s\n' "$out" | grep -q 'DRY-RUN role: builder' && ok "role defaults to builder with no COS_BUILDER_DIRS" || bad "role default" "$out"
printf 'COS_BUILDER_DIRS=%q\n' "$T/elsewhere" >> "$T/config.env"
out=$(run --task-file "$NEW")
printf '%s\n' "$out" | grep -q 'DRY-RUN role: non-dev' && ok "dir outside COS_BUILDER_DIRS → non-dev" || bad "role non-dev" "$out"

# 9. COS_SPAWN_ENV_CMD: KEY=VALUE lines exported to the worker, bad keys dropped, values never in the output
printf '#!/bin/sh\necho "WORKER_SECRET_X=v4lue-$2"\necho "bad-key=1"\necho "noise line"\n' > "$T/envcmd"; chmod +x "$T/envcmd"
printf 'COS_SPAWN_ENV_CMD=%q\n' "$T/envcmd" >> "$T/config.env"
out=$(run --task-file "$NEW")
printf '%s\n' "$out" | grep -q 'v4lue' && bad "env value printed in dry run" "$out" || ok "env values never printed by spawn"
argv_of "$out" >/dev/null
grep -qx 'WORKER_SECRET_X=v4lue-m-docs-new' "$T/argv.env" && ok "COS_SPAWN_ENV_CMD line exported (got task + name args)" || bad "env export" "$(grep WORKER "$T/argv.env")"
grep -q '^bad-key=' "$T/argv.env" && bad "invalid key exported" || ok "invalid key names dropped"

echo "PASS $PASS FAIL $FAIL"
[ "$FAIL" = 0 ]
