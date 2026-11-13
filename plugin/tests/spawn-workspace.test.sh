#!/usr/bin/env bash
# Tests for spawn.sh cmux workspace routing (COS_LAUNCHER=cmux): task `title:` → tab title; task `workspace_title:` →
# that workspace, created on first use from the ref `workspace create` RETURNS (the fake tree never lists the new
# workspace, so only that ref can place the pane right) with its placeholder closed after the worker pane exists;
# chief tasks → $COS_CHIEF_WORKSPACE_TITLE; $COS_CMUX_WORKSPACE_ROUTES; then the pin, then $COS_CMUX_WORKSPACE_TITLE.
# Throwaway COS_DIR, HOME and config (AGENT_OPS_CONFIG); a fake `cmux` on PATH logs argv and prints $FAKE_TREE.
# Run: bash plugin/tests/spawn-workspace.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS="$HERE/../skills/chief-of-staff/scripts"
T=$(mktemp -d "${TMPDIR:-/tmp}/spawnws.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
unset COS_WORKER COS_DIR COS_MACHINE_PREFIX COS_HOST_PREFIX COS_LAUNCHER COS_CMUX_TMUX COS_TMUX_SOCKET TMUX \
  COS_CMUX_WORKSPACE COS_CMUX_WORKSPACE_TITLE COS_CHIEF_WORKSPACE_TITLE COS_CMUX_WORKSPACE_ROUTES COS_SPAWN_WORKSPACE

mkdir -p "$T/cos/tasks" "$T/repo" "$T/home/.claude/sessions" "$T/bin"
WSU=11111111-2222-4333-8444-555555555555 PHU=AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE
# fake cmux: logs argv; `tree` prints $FAKE_TREE (empty on the first call when FAKE_TREE_EMPTY_ONCE=1);
# `workspace create --json` returns ids; new-pane returns a surface
cat > "$T/bin/cmux" <<F
#!/bin/bash
printf '%s\n' "\$*" >> "\$FAKE_LOG"
case " \$* " in
  *" workspace create "*) printf '{"workspace_id":"$WSU","workspace_ref":"workspace:77","surface_id":"$PHU","surface_ref":"surface:900"}\n';;
  *" tree "*) if [ "\${FAKE_TREE_EMPTY_ONCE:-0}" = 1 ] && [ ! -f "$T/tree-seen" ]; then : > "$T/tree-seen"; else printf '%b' "\${FAKE_TREE:-}"; fi;;
  *" new-pane "*|*" new-split "*) printf 'OK surface:901 pane:300 workspace:77\n';;
esac
exit 0
F
printf '#!/bin/sh\nexit 0\n' > "$T/bin/claude"
chmod +x "$T/bin/"*
export FAKE_LOG="$T/cmux.log"

cfg() {  # cfg EXTRA-LINES… → $T/config.env
  { printf 'COS_DIR=%q\nCOS_MACHINE_PREFIX=a\nCOS_HOST_PREFIX=a\nCOS_LAUNCH_DIRS=%q\nCOS_LAUNCHER=cmux\nCOS_CMUX_BIN=%q\nCOS_CLAUDE_BIN=%q\n' \
      "$T/cos" "$T/repo" "$T/bin/cmux" "$T/bin/claude"
    for l in "$@"; do printf '%s\n' "$l"; done; } > "$T/config.env"
}
newtask() {  # newtask NAME EXTRA-FRONTMATTER-LINES… → $T/cos/tasks/NAME.md (path in $TASK)
  local n="$1"; shift; TASK="$T/cos/tasks/$n.md"
  { printf -- '---\nname: %s\nto: a\ndir: %s\nmodel: sonnet\nstatus: open\n' "$n" "$T/repo"
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n- Task goal: write the doc.\n- Done means: doc merged.\n- parent goal: none\n'; } > "$TASK"
}
run() { rm -f "$FAKE_LOG" "$T/tree-seen"; HOME="$T/home" PATH="$T/bin:$PATH" AGENT_OPS_CONFIG="$T/config.env" bash "$SCRIPTS/spawn.sh" --task-file "$TASK" --no-goal --force "$@" 2>&1; }
wsline() { printf '%s\n' "$1" | grep '^DRY-RUN workspace:'; }
TREE_BASE='  workspace workspace:1 "chief"\n  workspace workspace:3 "pinned"\n'

# 1. workspace_title, first use: real spawn; pane goes in the CREATED ref; placeholder closed after the pane; title
cfg; newtask a-support-x "workspace_title: SUPPORT" "title: Login bug for the support desk"
out=$(FAKE_TREE="$TREE_BASE" run); rc=$?; log=$(cat "$FAKE_LOG" 2>/dev/null)
[ "$rc" = 0 ] && ok "workspace_title spawn exits 0" || bad "spawn rc" "rc=$rc $out"
printf '%s\n' "$log" | grep -q -- '--json --id-format both workspace create --name SUPPORT' && ok "creates the titled workspace" || bad "create" "$log"
printf '%s\n' "$log" | grep -E 'new-(pane|split) ' | grep -q -- '--workspace workspace:77 ' && ok "worker pane goes in the CREATED workspace" || bad "pane target" "$log"
printf '%s\n' "$log" | grep -E 'new-(pane|split) ' | grep -q -- '--workspace workspace:1 ' && bad "pane landed in the default workspace" "$log" || ok "worker pane never in the default workspace"
printf '%s\n' "$log" | grep -q "close-surface --workspace $WSU --surface $PHU" && ok "placeholder surface closed" || bad "placeholder close" "$log"
np=$(printf '%s\n' "$log" | grep -n 'new-pane ' | head -1 | cut -d: -f1); cs=$(printf '%s\n' "$log" | grep -n 'close-surface ' | head -1 | cut -d: -f1)
[ -n "$np" ] && [ -n "$cs" ] && [ "$np" -lt "$cs" ] && ok "placeholder closed only after the worker pane exists" || bad "order" "new-pane@$np close@$cs"
[ "$(printf '%s\n' "$log" | grep -c '^tree ')" = 1 ] && ok "no tree re-read after create" || bad "tree reads" "$log"
printf '%s\n' "$log" | grep -q 'tab-action --action rename .*--title Login bug for the support desk' && ok "task title: names the tab" || bad "tab title" "$log"
printf '%s\n' "$out" | grep -q 'OK spawned a-support-x (cmux ws77/surface:901' && ok "OK line reports ws77" || bad "OK line" "$out"

# 2. workspace_title that already exists: no create; dry run names the rule
newtask a-support-y "workspace_title: support"
out=$(FAKE_TREE="$TREE_BASE"'  workspace workspace:5 "SUPPORT"\n' run --dry-run)
wsline "$out" | grep -q 'workspace:5 (task workspace_title "support")' && ok "existing titled workspace reused (case-insensitive)" || bad "existing title" "$(wsline "$out")"
grep -q 'workspace create' "$FAKE_LOG" && bad "dry run created a workspace" "$(cat "$FAKE_LOG")" || ok "no create when it exists"
newtask a-support-z "workspace_title: NEWDESK"
out=$(FAKE_TREE="$TREE_BASE" run --dry-run)
wsline "$out" | grep -q 'would create "NEWDESK"' && ! grep -q 'workspace create' "$FAKE_LOG" && ok "dry run: would create, creates nothing" || bad "dry create" "$out"

# 3. chief task → CHIEF before the pin; role from task or name; missing → WARN + next rule
cfg COS_CMUX_WORKSPACE=workspace:3
newtask a-ops-x "role: chief"
# titles match case-insensitively, so with both defaults "CHIEF" and "chief" are one workspace: the tree here has no "chief"
out=$(FAKE_TREE='  workspace workspace:3 "pinned"\n  workspace workspace:9 "CHIEF"\n' run --dry-run)
wsline "$out" | grep -q 'workspace:9 (chief task' && ok "role: chief → CHIEF before the pin" || bad "chief role" "$(wsline "$out")"
newtask a-ops-chief
cfg COS_CMUX_WORKSPACE=workspace:3 COS_CHIEF_WORKSPACE_TITLE=chief-room
out=$(FAKE_TREE="$TREE_BASE"'  workspace workspace:9 "chief-room"\n' run --dry-run)
wsline "$out" | grep -q 'workspace:9 (chief task → workspace "chief-room")' && ok "*-chief name + COS_CHIEF_WORKSPACE_TITLE" || bad "chief name" "$(wsline "$out")"
out=$(FAKE_TREE="$TREE_BASE" run --dry-run)
printf '%s\n' "$out" | grep -q 'WARN: chief task but no workspace titled "chief-room"' && wsline "$out" | grep -q 'workspace:3 (COS_CMUX_WORKSPACE pin)' \
  && ok "no chief workspace → WARN, falls to the pin" || bad "chief missing" "$out"

# 4. COS_CMUX_WORKSPACE_ROUTES
cfg COS_CMUX_WORKSPACE=workspace:3 'COS_CMUX_WORKSPACE_ROUTES="*REVIEW*=REVIEW; *docs/*=DOCS ; *review*=OTHER"'
TREE_R="$TREE_BASE"'  workspace workspace:4 "review"\n  workspace workspace:6 "DOCS"\n  workspace workspace:8 "OTHER"\n'
newtask a-review-x
out=$(FAKE_TREE="$TREE_R" run --dry-run)
wsline "$out" | grep -q 'workspace:4 (route \*review\* → workspace "REVIEW")' && ok "route on name, case-insensitive, first match wins" || bad "route name" "$(wsline "$out")"
newtask a-misc-x "lane: docs/guides"
out=$(FAKE_TREE="$TREE_R" run --dry-run)
wsline "$out" | grep -q 'workspace:6 (route \*docs/\* → workspace "DOCS")' && ok "route on task lane:" || bad "route lane" "$(wsline "$out")"
newtask a-misc-y "category: Review"
out=$(FAKE_TREE="$TREE_R" run --dry-run)
wsline "$out" | grep -q 'workspace:4 (route' && ok "route on task category:" || bad "route category" "$(wsline "$out")"
newtask a-review-y
out=$(FAKE_TREE="$TREE_BASE" run --dry-run)
printf '%s\n' "$out" | grep -q 'WARN: route \*review\* matches but no workspace titled "REVIEW"' && wsline "$out" | grep -q 'workspace:3 (COS_CMUX_WORKSPACE pin)' \
  && ok "route target missing → WARN, falls to the pin" || bad "route missing" "$out"
grep -q 'workspace create' "$FAKE_LOG" && bad "route created a workspace" "$(cat "$FAKE_LOG")" || ok "route never creates a workspace"
newtask a-plain-x
out=$(FAKE_TREE="$TREE_R" run --dry-run)
wsline "$out" | grep -q 'workspace:3 (COS_CMUX_WORKSPACE pin)' && ok "no route match → the pin" || bad "no match" "$(wsline "$out")"

# 5. title fallback, empty-tree retry, no workspace at all
cfg
out=$(FAKE_TREE="$TREE_BASE" run --dry-run)
wsline "$out" | grep -q 'workspace:1 (workspace titled "chief")' && ok "default: workspace titled chief" || bad "title fallback" "$(wsline "$out")"
out=$(FAKE_TREE="$TREE_BASE" FAKE_TREE_EMPTY_ONCE=1 run --dry-run)
[ "$(grep -c '^tree ' "$FAKE_LOG")" = 2 ] && wsline "$out" | grep -q 'workspace:1' && ok "empty tree retried once" || bad "retry" "$(cat "$FAKE_LOG") $(wsline "$out")"
out=$(FAKE_TREE='' run --dry-run)
wsline "$out" | grep -q 'none (no rule matched)' && ok "no workspace → new-workspace fallback" || bad "none" "$(wsline "$out")"

echo "PASS $PASS FAIL $FAIL"
[ "$FAIL" = 0 ]
