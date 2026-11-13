#!/bin/bash
# Tests for hooks/send-cold-guard.py SendMessage to a cold (>= 50 min) or stopped/parked/done local session is denied.
# Run: bash plugin/tests/send-cold-guard.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); G="$HERE/../hooks/send-cold-guard.py"
T=$(mktemp -d -t scg); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sess" "$T/proj/-w" "$T/cos/tasks"
export COS_SESSIONS_DIR="$T/sess" COS_PROJECTS_DIR="$T/proj" COS_DIR="$T/cos"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
sess() {   # sess NAME MINS_AGO STATUS
  printf '{"pid":%d,"name":"%s","sessionId":"sid-%s","cwd":"/w"}' "$$" "$1" "$1" > "$T/sess/$1.json"
  python3 -c "import datetime,sys; t=datetime.datetime.utcnow()-datetime.timedelta(minutes=int(sys.argv[2])); print('{\"type\":\"assistant\",\"timestamp\":\"%sZ\"}' % t.isoformat(timespec='milliseconds'))" x "$2" > "$T/proj/-w/sid-$1.jsonl"
  printf -- '---\nname: %s\nstatus: %s\n---\n' "$1" "$3" > "$T/cos/tasks/$1.md"
}
send() { printf '{"tool_name":"SendMessage","tool_input":{"to":"%s","message":"%s"}}' "$1" "${2:-hi}" | python3 "$G"; }
sess a-warm 10 running; sess a-cold 55 running; sess a-parked 5 parked; sess a-stopped 5 stopped
[ -z "$(send a-warm)" ] && ok "warm (10 min) running → allowed" || bad "warm allowed" "$(send a-warm)"
o=$(send a-cold); grep -q '"deny"' <<<"$o" && grep -q "55 min ago" <<<"$o" && grep -q -- "--continues a-cold" <<<"$o" && ok "cold 55 min → deny + last turn time + --continues hint" || bad "cold deny" "$o"
[ -z "$(send a-parked)" ] && ok "parked, live pid, warm → allowed" || bad "parked warm allowed" "$(send a-parked)"
[ -z "$(send a-stopped)" ] && ok "stopped, live pid, warm → allowed" || bad "stopped warm allowed" "$(send a-stopped)"
[ -z "$(send a-cold '# cold-ok: user asked')" ] && ok "# cold-ok: escape → allowed" || bad "escape"
[ -z "$(send 'a-cold [abc]' '# cold-ok: x')" ] && grep -q deny <<<"$(send 'a-cold [abc]')" && ok "'name [ref]' resolves to name" || bad "ref strip"
[ -z "$(send a-nobody)" ] && ok "unknown target (subagent / cloud) → allowed" || bad "unknown allowed"
echo '{bad json' | python3 "$G"; [ $? = 0 ] && ok "bad input fails open" || bad "fail open"
echo "PASS $PASS FAIL $FAIL"; [ "$FAIL" = 0 ]
