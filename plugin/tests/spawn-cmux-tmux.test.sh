#!/usr/bin/env bash
# Tests for the cmux + tmux launcher mode (COS_LAUNCHER=cmux, COS_CMUX_TMUX=1): spawn.sh puts claude in its own tmux
# session and the cmux pane only attaches; stop.sh kills that session. Throwaway COS_DIR, HOME and config; fake
# `cmux` and `tmux` binaries on PATH log their argv. Dry runs first, then one full spawn + stop against the fakes.
# Run: bash plugin/tests/spawn-cmux-tmux.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS="$HERE/../skills/chief-of-staff/scripts"
T=$(mktemp -d "${TMPDIR:-/tmp}/spawncmuxtmux.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
unset COS_WORKER COS_DIR COS_MACHINE_PREFIX COS_HOST_PREFIX COS_LAUNCHER COS_CMUX_TMUX COS_TMUX_SOCKET COS_TMUX_BIN TMUX

mkdir -p "$T/cos/tasks" "$T/repo" "$T/home/.claude/sessions" "$T/bin"
# fake cmux: logs argv; `tree` shows one workspace titled chief; new-pane returns a surface
cat > "$T/bin/cmux" <<'F'
#!/bin/sh
echo "$*" >> "$FAKE_LOG.cmux"
case "$1" in
  tree) echo '  workspace workspace:3 "chief"';;
  new-pane|new-split) echo 'OK surface:7';;
esac
exit 0
F
# fake tmux: logs argv; has-session succeeds only when FAKE_TMUX_HAS=1
cat > "$T/bin/tmux" <<'F'
#!/bin/sh
echo "$*" >> "$FAKE_LOG.tmux"
for a in "$@"; do [ "$a" = has-session ] && { [ "${FAKE_TMUX_HAS:-0}" = 1 ]; exit $?; }; done
exit 0
F
cp "$T/bin/tmux" "$T/bin/tmux-alt"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/claude"
chmod +x "$T/bin/"*
export FAKE_LOG="$T/log"

cfg() {  # cfg EXTRA-LINES… → $T/config.env
  { printf 'COS_DIR=%q\nCOS_MACHINE_PREFIX=a\nCOS_HOST_PREFIX=a\nCOS_LAUNCH_DIRS=%q\nCOS_LAUNCHER=cmux\nCOS_CMUX_BIN=%q\nCOS_CLAUDE_BIN=%q\n' \
      "$T/cos" "$T/repo" "$T/bin/cmux" "$T/bin/claude"
    for l in "$@"; do printf '%s\n' "$l"; done; } > "$T/config.env"
}
TASK="$T/cos/tasks/a-docs-x.md"
newtask() {
  cat > "$TASK" <<T2
---
name: a-docs-x
to: a
dir: $T/repo
model: sonnet
status: open
---
- Task goal: write the doc.
- Done means: doc merged.
- parent goal: none
T2
}
run()  { HOME="$T/home" PATH="$T/bin:$PATH" AGENT_OPS_CONFIG="$T/config.env" bash "$SCRIPTS/spawn.sh" --task-file "$TASK" --no-goal --force "$@" 2>&1; }
stop() { HOME="$T/home" PATH="$T/bin:$PATH" AGENT_OPS_CONFIG="$T/config.env" bash "$SCRIPTS/stop.sh" a-docs-x "$@" 2>&1; }
clear_logs() { rm -f "$FAKE_LOG".*; }

# 1. dry run, socket path: both steps printed, nothing created
newtask; cfg COS_CMUX_TMUX=1 "COS_TMUX_SOCKET=$T/sock"; clear_logs
out=$(run --dry-run); rc=$?
[ "$rc" = 0 ] && ok "dry run exits 0" || bad "dry run rc" "rc=$rc $out"
printf '%s\n' "$out" | grep -q "^DRY-RUN tmux (COS_CMUX_TMUX=1): tmux -S $T/sock new-session -d -s a-docs-x -c $T/repo .*a-docs-x.sh" \
  && ok "dry run prints the detached new-session on the socket (-S)" || bad "new-session line" "$out"
paneline() { printf '%s\n' "$1" | grep '^DRY-RUN: .* new-pane ' | tr -d '\\'; }   # %q escapes removed
pane=$(paneline "$out")
printf '%s' "$pane" | grep -qF "tmux -S $T/sock attach -t '=a-docs-x'" && ! printf '%s' "$pane" | grep -q 'a-docs-x\.sh' \
  && ok "pane command is the attach (not the launch script)" || bad "pane command" "$pane"
printf '%s\n' "$out" | grep -q '/tmux:a-docs-x' && ok "dry run names the /tmux:NAME where suffix" || bad "where suffix" "$out"
grep -q 'has-session -t =a-docs-x' "$FAKE_LOG.tmux" 2>/dev/null && ok "dry run checks for an existing session" || bad "has-session" "$(cat "$FAKE_LOG.tmux" 2>/dev/null)"
! grep -q 'new-session' "$FAKE_LOG.tmux" 2>/dev/null && ! grep -qE 'new-pane|new-split' "$FAKE_LOG.cmux" 2>/dev/null \
  && ok "dry run creates no session and no pane" || bad "dry run side effects" "$(cat "$FAKE_LOG".* 2>/dev/null)"

# 2. a session of that name exists → refuse (exit 2)
out=$(FAKE_TMUX_HAS=1 run --dry-run); rc=$?
[ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'tmux session a-docs-x already exists' && ok "existing session → exit 2" || bad "existing session" "rc=$rc $out"

# 3. socket name → -L; COS_TMUX_BIN picks the binary
cfg COS_CMUX_TMUX=1 COS_TMUX_SOCKET=agents "COS_TMUX_BIN=$T/bin/tmux-alt"
out=$(run --dry-run)
printf '%s\n' "$out" | grep -q "^DRY-RUN tmux (COS_CMUX_TMUX=1): $T/bin/tmux-alt -L agents new-session" \
  && paneline "$out" | grep -qF "tmux-alt -L agents attach -t '=a-docs-x'" \
  && ok "COS_TMUX_BIN + socket name (-L) used for both steps" || bad "bin/-L" "$out"

# 4. COS_CMUX_TMUX unset (default 0) → plain cmux pane running the launch script
cfg
out=$(run --dry-run)
! printf '%s\n' "$out" | grep -q 'new-session' && printf '%s\n' "$out" | grep '^DRY-RUN: .* new-pane ' | grep -q 'a-docs-x\.sh' \
  && ok "default 0: no tmux, pane runs the launch script" || bad "default off" "$out"

# 5. full spawn against the fakes: session first, then the attach pane; where gets /tmux:NAME
cfg COS_CMUX_TMUX=1 "COS_TMUX_SOCKET=$T/sock"; newtask; clear_logs
out=$(run --light); rc=$?
[ "$rc" = 0 ] && ok "spawn exits 0" || bad "spawn rc" "rc=$rc $out"
grep -q "^-S $T/sock new-session -d -s a-docs-x -c $T/repo " "$FAKE_LOG.tmux" 2>/dev/null && ok "spawn created the detached tmux session" || bad "spawn new-session" "$(cat "$FAKE_LOG.tmux" 2>/dev/null)"
grep -E '^new-pane ' "$FAKE_LOG.cmux" 2>/dev/null | grep -q "attach -t '=a-docs-x'" && ok "spawn opened the attach pane" || bad "spawn pane" "$(cat "$FAKE_LOG.cmux" 2>/dev/null)"
w=$(grep "^where:" "$TASK" | head -1 | tr -d "\"")
[ "$w" = "where: cmux ws3/surface:7/tmux:a-docs-x" ] && ok "task where: has the /tmux:NAME suffix" || bad "where" "$w"

# 6. stop --dry-run names the kill; stop kills the session, then closes the pane
printf -- '- status: WORKING · session: sessions/x.md\n' >> "$TASK"
clear_logs
out=$(stop --dry-run); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'DRY-RUN: would kill tmux session a-docs-x' && ok "stop --dry-run names the tmux kill" || bad "stop dry" "rc=$rc $out"
! grep -q kill-session "$FAKE_LOG.tmux" 2>/dev/null && ok "stop --dry-run kills nothing" || bad "stop dry side effect" "$(cat "$FAKE_LOG.tmux")"
grep -q "capture-pane -p -t =a-docs-x:" "$FAKE_LOG.tmux" 2>/dev/null && ok "subagent gate reads the tmux session screen" || bad "capture-pane" "$(cat "$FAKE_LOG.tmux" 2>/dev/null)"
sed -i.bak 's/^status: .*/status: running/' "$TASK"; clear_logs
out=$(stop); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'killed tmux session a-docs-x' && ok "stop kills the tmux session" || bad "stop kill" "rc=$rc $out"
grep -q "^-S $T/sock kill-session -t =a-docs-x" "$FAKE_LOG.tmux" 2>/dev/null && ok "kill-session on the configured socket" || bad "kill-session argv" "$(cat "$FAKE_LOG.tmux" 2>/dev/null)"
grep -q 'close-surface --workspace workspace:3 --surface surface:7' "$FAKE_LOG.cmux" 2>/dev/null && ok "stop still closes the pane" || bad "close-surface" "$(cat "$FAKE_LOG.cmux" 2>/dev/null)"
grep -q '^status: stopped' "$TASK" && ok "task closed (status: stopped)" || bad "task status" "$(grep '^status' "$TASK")"

# 7. checkin's pane target still parses from the suffixed where (ws/surface regex, not anchored)
python3 -c 'import re,sys; m=re.search(r"ws(\d+)/(surface:\d+)", sys.argv[1]); sys.exit(0 if m and m.group(2)=="surface:7" else 1)' "cmux ws3/surface:7/tmux:a-docs-x" \
  && ok "checkin ws/surface regex matches a /tmux: where" || bad "checkin regex"

echo "---"; echo "pass $PASS  fail $FAIL"
[ "$FAIL" = 0 ]
