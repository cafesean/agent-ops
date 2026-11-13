#!/bin/bash
# Tests for hooks/mini-run-guard.sh — feeds PreToolUse JSON, asserts allow/deny.
# Run: bash plugin/tests/mini-run-hook.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../hooks/mini-run-guard.sh"
T=$(mktemp -d -t minirunguard)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/code/repo/src" "$T/code/norepo" "$T/outside"
echo '{}' > "$T/code/repo/package.json"
printf '#!/bin/bash\nsleep 5\n' > "$T/slow-mini"; chmod +x "$T/slow-mini"

export COS_HEAVY_GUARD_ROOT="$T/code"
export COS_MINI_RUN_BIN=true          # remote runner reachable by default
unset COS_ALLOW_LOCAL_HEAVY
REPO="$T/code/repo"
PASS=0 FAIL=0

# check <expect allow|deny> <name> <cwd> <command> [env assignments...]
check() {
  local want=$1 name=$2 cwd=$3 cmd=$4; shift 4
  local json out got
  json=$(python3 -c 'import json,sys;print(json.dumps({"session_id":"t","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$cwd" "$cmd")
  out=$(printf '%s' "$json" | env "$@" bash "$HOOK" 2>/dev/null); rc=$?
  if printf '%s' "$out" | grep -q '"permissionDecision": "deny"'; then got=deny; else got=allow; fi
  [ $rc = 0 ] || got="rc$rc"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); printf 'ok   %-5s %s\n' "$want" "$name"
  else FAIL=$((FAIL+1)); printf 'FAIL want %s got %s: %s\n     cmd: %s\n     out: %s\n' "$want" "$got" "$name" "$cmd" "$out"; fi
  LAST_OUT=$out
}

# --- heavy → deny
check deny  "bare tsc --noEmit"            "$REPO" "tsc --noEmit"
check deny  "pnpm typecheck"               "$REPO" "pnpm typecheck"
check deny  "pnpm exec tsc"                "$REPO" "pnpm exec tsc --noEmit -p tsconfig.json"
check deny  "npx tsc"                      "$REPO" "npx tsc --noEmit"
check deny  "next build"                   "$REPO" "npx next build"
check deny  "pnpm build"                   "$REPO" "pnpm build"
check deny  "pnpm run build"               "$REPO" "pnpm run build"
check deny  "pnpm -r build"                "$REPO" "pnpm -r build"
check deny  "turbo build"                  "$REPO" "turbo run build --filter=web"
check deny  "vitest run full"              "$REPO" "pnpm vitest run"
check deny  "vitest run --dir src (full)"  "$REPO" "npx vitest run --dir src --reporter dot"
check deny  "pnpm test full"               "$REPO" "pnpm test"
check deny  "pnpm run test full"           "$REPO" "pnpm run test 2>&1 | tail -40"
check deny  "rtk-prefixed tsc"             "$REPO" "rtk tsc --noEmit"
check deny  "rtk pnpm test"                "$REPO" "rtk pnpm test"
check deny  "cd chain → pnpm build"        "$T/code" "cd repo && pnpm build"
case "$LAST_OUT" in *'cd repo && mini-run pnpm build'*) PASS=$((PASS+1)); echo "ok   deny  reason carries exact mini-run command";;
  *) FAIL=$((FAIL+1)); echo "FAIL reason missing 'cd repo && mini-run pnpm build': $LAST_OUT";; esac
check deny  "env prefix + timeout wrapper" "$REPO" "NODE_OPTIONS=--max-old-space-size=8192 timeout 600 pnpm typecheck"
check deny  "pnpm -C repo build from root" "$T/code" "pnpm -C repo build"

# --- not heavy / out of scope → allow
check allow "already mini-run"             "$REPO" "mini-run pnpm typecheck"
check allow "mini-run with cd"             "$T/code" "cd repo && mini-run 'pnpm test'"
check allow "targeted vitest file"         "$REPO" "pnpm vitest run src/foo.test.ts"
check allow "vitest -t filter"             "$REPO" "npx vitest run -t 'saves draft'"
check allow "pnpm test with path"          "$REPO" "pnpm test -- src/lib/x.spec.ts"
check allow "pnpm test --testNamePattern"  "$REPO" "pnpm test --testNamePattern=draft"
check allow "tsc single file"              "$REPO" "npx tsc --noEmit src/one.ts"
check allow "tsc --version"                "$REPO" "tsc --version"
check allow "escape: env in command"       "$REPO" "COS_ALLOW_LOCAL_HEAVY=1 pnpm build"
check allow "escape: env in environment"   "$REPO" "pnpm build" COS_ALLOW_LOCAL_HEAVY=1
check allow "escape: local-ok marker"      "$REPO" "pnpm test # local-ok: needs local postgres"
check allow "no package.json"              "$T/code/norepo" "tsc --noEmit"
check allow "outside the guard root"      "$T/outside" "pnpm build"
check allow "cd out of scope"              "$REPO" "cd $T/outside && pnpm build"
check allow "unrelated command"            "$REPO" "git status && ls src"
check allow "pnpm install"                 "$REPO" "pnpm install --frozen-lockfile"
check allow "grep for 'build' text"        "$REPO" "grep -rn build src"
check allow "runner down → allow (false)"  "$REPO" "pnpm build" COS_MINI_RUN_BIN=false
check allow "runner timeout 3s → allow"   "$REPO" "pnpm build" COS_MINI_RUN_BIN="$T/slow-mini"
# Not configured (no remote runner, no scope root) → hook is inert
check allow "unconfigured → inert"         "$REPO" "pnpm build" -u COS_HEAVY_GUARD_ROOT -u COS_MINI_RUN_BIN AGENT_OPS_CONFIG=/nonexistent

# --- mini-run probe: a busy remote is not a down remote. Full mini-run runs against a fake ssh on PATH that
# fails its first $FAKE_FAIL calls (exit 255, like a connect timeout), then answers. Past the probe the fake refuses
# the lock (LOCKFAIL → exit 90), so "used the remote" = exit 90 + no local marker; "ran locally" = the marker exists.
MR="$HERE/../skills/chief-of-staff/scripts/addons/mini-run.sh"
FB="$T/fakebin"; mkdir -p "$FB" "$T/mhome" "$T/mono/repo"
cat > "$FB/ssh" <<'FAKE'
#!/bin/bash
n=$(( $(cat "$FAKE_CNT" 2>/dev/null || echo 0) + 1 )); echo $n > "$FAKE_CNT"
[ "$n" -le "${FAKE_FAIL:-0}" ] && { echo "ssh: connect to host x port 22: Operation timed out" >&2; exit 255; }
last=${!#}
case "$last" in true) exit 0;; *"mini-run-remote status"*) echo "no locks held"; exit 0;; *) echo "LOCKFAIL fake"; exit 95;; esac
FAKE
chmod +x "$FB/ssh"
printf '#!/bin/bash\nexit 0\n' > "$FB/mini-ip-follow.sh"; chmod +x "$FB/mini-ip-follow.sh"
git -C "$T/mono/repo" init -q 2>/dev/null; echo '{}' > "$T/mono/repo/package.json"
# mr <name> <want-rc> <want: remote|local> <fake-fail> [env...] -- runs mini-run once from the temp repo
mr() {
  local name=$1 wrc=$2 where=$3 ff=$4; shift 4; rm -f "$T/ran-local" "$T/cnt"
  out=$(cd "$T/mono/repo" && env PATH="$FB:$PATH" HOME="$T/mhome" AGENT_OPS_CONFIG=/nonexistent MINI_RUN_HOST=fake@remote \
    COS_REMOTE_LAUNCH_DIRS="$T/mono=code/mono" MINI_RUN_PROBE_PAUSE=0 FAKE_CNT="$T/cnt" FAKE_FAIL=$ff \
    "$@" bash "$MR" --no-deps "touch $T/ran-local" 2>&1); rc=$?
  local got=remote; [ -f "$T/ran-local" ] && got=local
  if [ "$rc" = "$wrc" ] && [ "$got" = "$where" ]; then PASS=$((PASS+1)); printf 'ok   probe %s\n' "$name"
  else FAIL=$((FAIL+1)); printf 'FAIL probe %s: want rc %s %s, got rc %s %s\n     out: %s\n' "$name" "$wrc" "$where" "$rc" "$got" "$out"; fi
}
mr "answers 1st try → remote"               90 remote 0
mr "fails 2, answers 3rd → remote, not local" 90 remote 2
case "$out" in *"answered on probe 3/3"*) PASS=$((PASS+1)); echo "ok   probe says busy-not-down";; *) FAIL=$((FAIL+1)); echo "FAIL probe message: $out";; esac
mr "fails all 3 → local fallback"           0  local 3
mr "fails 4 of TRIES=5 → remote"            90 remote 4 MINI_RUN_PROBE_TRIES=5
mr "fails all, NO_LOCAL=1 → exit 90, no local" 90 remote 9 MINI_RUN_NO_LOCAL=1
case "$out" in *"unreachable"*"MINI_RUN_NO_LOCAL=1"*) PASS=$((PASS+1)); echo "ok   probe NO_LOCAL message";; *) FAIL=$((FAIL+1)); echo "FAIL NO_LOCAL message: $out";; esac
# --status: retried on ssh 255, never runs anything locally
st() { local name=$1 wrc=$2 ff=$3; rm -f "$T/cnt"
  out=$(cd "$T/mono/repo" && env PATH="$FB:$PATH" HOME="$T/mhome" AGENT_OPS_CONFIG=/nonexistent MINI_RUN_HOST=fake@remote \
    MINI_RUN_PROBE_PAUSE=0 FAKE_CNT="$T/cnt" FAKE_FAIL=$ff bash "$MR" --status 2>&1); rc=$?
  if [ "$rc" = "$wrc" ]; then PASS=$((PASS+1)); printf 'ok   status %s\n' "$name"; else FAIL=$((FAIL+1)); printf 'FAIL status %s: want rc %s got %s: %s\n' "$name" "$wrc" "$rc" "$out"; fi; }
st "fails 2, answers 3rd → 0" 0 2
st "fails all 3 → 255, nothing local" 255 3

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
