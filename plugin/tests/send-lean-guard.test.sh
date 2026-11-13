#!/bin/bash
# Tests for hooks/send-lean-guard.py (agent-ops 0.8.4): SendMessage that wakes a session for nothing (ack, "no reply needed",
# who-is-who broadcast) is denied; real messages pass. Cases are real messages.
# Run: bash chief-of-staff/tests/send-lean-guard.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); G="$HERE/../hooks/send-lean-guard.py"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
send() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"SendMessage","tool_input":{"to":"m-x-1","message":sys.argv[1]}}))' "$1" | python3 "$G"; }
deny()  { o=$(send "$2"); grep -q '"deny"' <<<"$o" && grep -q "$3" <<<"$o" && ok "$1" || bad "$1" "$o"; }
allow() { o=$(send "$2"); [ -z "$o" ] && ok "$1" || bad "$1" "$o"; }

deny  "bare ok → deny"                       "ok" "acknowledgement"
deny  "ack with name prefix → deny"          "worker-3 → lead-2: ack." "acknowledgement"
deny  "thanks → deny"                        "Thanks!" "acknowledgement"
deny  "no reply needed → deny"               "Your handoff point is now 800k. Hand over at the hook as normal. No reply needed." "need not reply"
deny  "FYI only → deny"                      "FYI only: release 330 merged." "need not reply"
deny  "new chief broadcast → deny"           "New chief = chief-7 (chief-6 retired); captain unchanged captain-4." "who-is-who"
deny  "captain is now broadcast → deny"      "chief-7: captain is now captain-5 (4 handed off at 709k)." "who-is-who"
deny  "deny names the task file"             "ok" "task file ## Reports"
allow "ack + real content → allowed"         "ack PROD LIVE 238948b79. Prod has had no sync job over 20k chars since go-live; a watcher polls hourly."
allow "release-request → allowed"            "RR shop fix/cart-total@0256336cd → prod · local: vitest 9/9"
allow "task with okay inside → allowed"      "lead-2 → worker-5: new item: prod 7 d checkout_start has 43 refusals with NO code. Okay to start now."
allow "long message opening with new captain → allowed" "New captain = captain-4. $(printf 'x%.0s' {1..420})"
allow "# wake-ok: escape → allowed"          "No reply needed. # wake-ok: the user asked every lane to know now"
COS_SEND_LEAN_GUARD=0 allow "kill switch → allowed" "ok"
o=$(echo '{bad json' | python3 "$G"); [ $? = 0 ] && [ -z "$o" ] && ok "bad input fails open" || bad "fail open" "$o"
o=$(echo '{"tool_name":"Bash","tool_input":{"command":"ok"}}' | python3 "$G"); [ -z "$o" ] && ok "other tool ignored" || bad "other tool" "$o"
echo "PASS $PASS FAIL $FAIL"; [ "$FAIL" = 0 ]
