#!/bin/bash
# Tests for hooks/worktree-owner.py (owner stamp, read by the stop.sh worktree gate) — temp git repos only.
# Run: bash plugin/tests/worktree-guard.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../hooks/worktree-owner.py"
T=$(mktemp -d -t wtguard)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/cos/tasks" "$T/mono" "$T/home/.claude/sessions"
printf 'COS_DIR=%q\n' "$T/cos" > "$T/config.env"
export AGENT_OPS_CONFIG="$T/config.env" HOME="$T/home"
unset COS_WORKER COS_WORKTREE_OWNER COS_WORKTREE_ROOTS COS_SPAWN_HEADLESS COS_REPORT_FILE
export COS_HEARTBEAT_DIR="$T/cos/.heartbeat"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

R="$T/mono/repo1"
git init -q -b main "$R" && git -C "$R" commit -q --allow-empty -m init

hook() {   # hook WORKER TOOL JSON-INPUT [JSON-RESPONSE]
  local resp="${4:-}"; [ -n "$resp" ] || resp='{}'
  printf '{"tool_name":"%s","session_id":"s1","cwd":"%s","tool_input":%s,"tool_response":%s}' "$2" "$R" "$3" "$resp" \
    | COS_WORKER="$1" python3 "$HOOK"
}
owner_of() { head -1 "$R/.git/worktrees/$1/cos-owner" 2>/dev/null; }

# 1. hook stamps a Bash `cd … && git worktree add` (relative path, -b option)
git -C "$R" worktree add -q -b b1 ../wt1
hook a-test Bash "{\"command\":\"cd $R && git worktree add -b b1 ../wt1\"}"
[ "$(owner_of wt1)" = a-test ] && ok "hook stamps Bash worktree add (cd + relative path)" || bad "hook stamps Bash worktree add" "$(ls "$R/.git/worktrees/wt1")"
grep -qx "$R/.git/worktrees/wt1" "$T/cos/.worktrees/a-test" 2>/dev/null && ok "hook appends registry line" || bad "hook registry line" "$(cat "$T/cos/.worktrees/a-test" 2>&1)"

# 2. hook stamps `git -C <repo> worktree add --detach <abs>` too
git -C "$R" worktree add -q --detach "$T/mono/wt2"
hook a-test Bash "{\"command\":\"git -C $R worktree add --detach $T/mono/wt2 HEAD\"}"
[ "$(owner_of wt2)" = a-test ] && ok "hook stamps git -C … --detach <abs path>" || bad "hook stamps -C form"

# 3. EnterWorktree: path found in tool_response
git -C "$R" worktree add -q -b b3 "$T/mono/wt3"
hook a-test EnterWorktree '{"name":"wt3"}' "{\"path\":\"$T/mono/wt3\"}"
[ "$(owner_of wt3)" = a-test ] && ok "hook stamps EnterWorktree from tool_response path" || bad "hook stamps EnterWorktree"

# 4. not a worker / kill switch → no stamp
git -C "$R" worktree add -q -b b4 "$T/mono/wt4"
hook "" Bash "{\"command\":\"git -C $R worktree add -b b4 $T/mono/wt4\"}"
COS_WORKTREE_OWNER=0 hook a-test Bash "{\"command\":\"git -C $R worktree add -b b4 $T/mono/wt4\"}"
[ -z "$(owner_of wt4)" ] && ok "no stamp without COS_WORKER or with COS_WORKTREE_OWNER=0" || bad "no stamp for non-worker / kill switch"

# 5. another owner's worktree is stamped with its own name
hook a-other Bash "{\"command\":\"git -C $R worktree add -b b4 $T/mono/wt4\"}"
[ "$(owner_of wt4)" = a-other ] && ok "hook stamps a second worker's worktree with its name" || bad "second owner stamp"

# 6. the registered entry (cos-py.sh) is inactive without an agent-ops config
git -C "$R" worktree add -q -b b6 "$T/mono/wt6"
IN6=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"git -C %s worktree add -b b6 %s/mono/wt6"},"tool_response":{}}' "$R" "$R" "$T")
printf '%s' "$IN6" | AGENT_OPS_CONFIG="$T/no-config" COS_WORKER=a-test bash "$HERE/../hooks/cos-py.sh" worktree-owner.py
[ -z "$(owner_of wt6)" ] && ok "cos-py.sh: no config → hook inactive" || bad "cos-py.sh inactive without config"
printf '%s' "$IN6" | COS_WORKER=a-test bash "$HERE/../hooks/cos-py.sh" worktree-owner.py
[ "$(owner_of wt6)" = a-test ] && ok "cos-py.sh: config present → hook runs" || bad "cos-py.sh runs with config"

echo "worktree-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
