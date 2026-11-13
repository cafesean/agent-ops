#!/bin/bash
# Tests for cos_focus_keep (addons/lib/cmux-equalize.sh) — a new pane must never keep the owner's keyboard focus or their
# visible workspace. Fake cmux: `rpc surface.current` answers from $T/now; focus-panel calls are logged.
# Run: bash plugin/tests/focus-guard.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/focusguard.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

cat > "$T/cmux" <<F
#!/bin/bash
printf '%s\n' "\$*" >> "$T/cmux.log"
case " \$* " in
  *" rpc surface.current "*) read -r w s < "$T/now"; printf '{"workspace_ref":"%s","surface_ref":"%s"}\n' "\$w" "\$s";;
esac
F
chmod +x "$T/cmux"
export COS_CMUX_BIN="$T/cmux" COS_DIR="$T/cos"
. "$HERE/../skills/chief-of-staff/scripts/addons/lib/cmux-equalize.sh"
run() { : > "$T/cmux.log"; printf '%s\n' "$1" > "$T/now"; cos_focus_keep "workspace:102 surface:1430" "$2" "$3" test 2>/dev/null; }
restored() { grep -q '^focus-panel --panel surface:1430 --workspace workspace:102$' "$T/cmux.log"; }

printf 'workspace:102 surface:1430\n' > "$T/now"
[ "$(cos_focus_snap)" = "workspace:102 surface:1430" ] && ok "snap reads workspace + surface" || bad "snap" "$(cos_focus_snap)"

run "workspace:103 surface:1463" workspace:103 surface:1463
restored && ok "window moved to the new pane  → restored" || bad "steal to new pane" "$(cat "$T/cmux.log")"
grep -q 'step=test was=workspace:102 surface:1430 now=workspace:103 surface:1463' "$T/cos/logs/focus-steal.log" \
  && ok "steal logged with its step" || bad "log" "$(cat "$T/cos/logs/focus-steal.log" 2>/dev/null)"

run "workspace:103 surface:1400" workspace:103 surface:1463
restored && ok "window moved to another pane of the target workspace → restored" || bad "steal to target ws" "$(cat "$T/cmux.log")"

run "workspace:102 surface:1463" workspace:102 surface:1463
restored && ok "new pane in the owner's own workspace took focus → restored" || bad "steal same ws" "$(cat "$T/cmux.log")"

run "workspace:102 surface:1430" workspace:103 surface:1463
restored && bad "no move → no restore" || ok "no move → no restore"

run "workspace:98 surface:1445" workspace:103 surface:1463
restored && bad "owner clicked elsewhere → left alone" || ok "owner clicked elsewhere → left alone"

run "workspace:102 surface:1406" workspace:102 surface:1463
restored && bad "owner clicked another pane in their workspace → left alone" || ok "owner clicked another pane in their workspace → left alone"

printf '\nPASS %s FAIL %s\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
