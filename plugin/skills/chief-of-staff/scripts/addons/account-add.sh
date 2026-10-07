#!/usr/bin/env bash
# Store a second (third…) Claude account's long-lived token in the macOS Keychain, so spawn.sh --account <id>
# can start worker panes on it.
#   account-add.sh <id>          run `claude setup-token` (browser sign-in as the OTHER account), capture the token
#                                from its output (no copy-paste), store it as Keychain item cos-claude-account-<id>
#   account-add.sh --list        ids + sha256 fingerprint prefix (never the token)
#   account-add.sh --remove <id> delete the Keychain item
# id: lowercase, e.g. b, c. `a` is the default Keychain login (`Claude Code-credentials`) — never stored here.
# The token never touches disk, argv, or this script's output: it goes on stdin to `security -i` as an
# add-generic-password command (a bare `-w` would prompt on the tty). Only its length + fingerprint are printed.
# Adds the id to $COS_DIR/accounts.md as `ok`.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../cos-env.sh" || exit 1
[ "$COS_OS" = mac ] || { echo "addon accounts: macOS only, skipping"; exit 0; }   # tokens live in the macOS Keychain
[ -n "${COS_ACCOUNTS:-}${COS_DEFAULT_ACCOUNT:-}" ] || { echo "addon accounts not configured, skipping"; exit 0; }
SVC=cos-claude-account-
fp() { security find-generic-password -a "$USER" -s "$SVC$1" -w 2>/dev/null | tr -d '\n' | shasum -a 256 | cut -c1-12; }
ids() { security dump-keychain 2>/dev/null | sed -nE "s/^.*\"svce\"<blob>=\"$SVC([a-z][a-z0-9]*)\"$/\1/p" | sort -u; }
valid_id() { [[ "$1" =~ ^[a-z][a-z0-9]{0,5}$ ]] && [ "$1" != a ]; }

case "${1:-}" in
  --list)
    n=0; for i in $(ids); do printf '%-6s sha256:%s…\n' "$i" "$(fp "$i")"; n=$((n+1)); done
    echo "a      (default Keychain login — not stored here)"; [ "$n" -gt 0 ] || echo "no extra accounts stored — run: account-add.sh b"
    exit 0;;
  --remove)
    id="${2:-}"; valid_id "$id" || { echo "usage: account-add.sh --remove <id>  (not a)" >&2; exit 2; }
    security delete-generic-password -a "$USER" -s "$SVC$id" >/dev/null 2>&1 && echo "removed Keychain item $SVC$id" \
      || { echo "no Keychain item $SVC$id" >&2; exit 1; }
    exit 0;;
  ""|-h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
esac
id="$1"
[ "$id" != a ] || { echo "a is the default Keychain login — nothing to store. Add the OTHER account: account-add.sh b" >&2; exit 2; }
valid_id "$id" || { echo "bad id '$id' — lowercase letter then up to 5 [a-z0-9], e.g. b" >&2; exit 2; }
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 1; }

echo "A browser opens: sign in with the account you want as '$id' (NOT your usual one) and approve." >&2
echo "The token is captured automatically — do not copy it anywhere." >&2
out=$(script -q /dev/null bash -c 'stty cols 500 2>/dev/null; claude setup-token' | tee /dev/tty)
tok=$(printf '%s' "$out" | cos_python -c '
import sys,re
t=re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07","",sys.stdin.read()).replace("\r","")
m=re.search(r"sk-ant-oat\d+-[A-Za-z0-9_-]+(?:\n[A-Za-z0-9_-]+(?=\n))*",t)
print(m.group(0).replace("\n","") if m else "")')
unset out
[ -n "$tok" ] || { echo "No token found in the setup-token output — nothing stored." >&2; exit 1; }
printf '\033[2J\033[3J\033[H' >/dev/tty 2>/dev/null || true   # clear the screen + scrollback that showed the token
case "$tok" in sk-ant-*) ;; *) unset tok; echo "Captured text does not start with sk-ant- — nothing stored." >&2; exit 1;; esac
[[ "$tok" =~ ^[A-Za-z0-9_-]+$ ]] || { unset tok; echo "Captured token has unexpected characters — nothing stored." >&2; exit 1; }
[ "${#tok}" -ge 90 ] || { n=${#tok}; unset tok; echo "Captured token is only $n chars (expected ~100+) — nothing stored." >&2; exit 1; }
len=${#tok}
# `add-generic-password -w` with no value prompts on /dev/tty (ignores stdin) — so feed the whole command to
# `security -i` on stdin instead: printf is a builtin, so the token is never in any process's argv, nor on disk.
# The token and id are [A-Za-z0-9_-] only (checked above), so they need no quoting in security's command parser.
printf 'add-generic-password -U -a "%s" -s "%s" -l "%s" -w %s\n' "$USER" "$SVC$id" "Claude account $id (chief-of-staff)" "$tok" \
  | security -i >/dev/null 2>&1
unset tok
security find-generic-password -a "$USER" -s "$SVC$id" >/dev/null 2>&1; rc=$?   # `security -i` exits 0 even when a command fails
[ "$rc" = 0 ] || { echo "security add-generic-password failed (exit $rc) — nothing stored." >&2; exit 1; }
echo "Stored account '$id' in Keychain item $SVC$id: $len chars, sha256:$(fp "$id")…" >&2
"$HERE/account-limit.sh" --clear "$id" >/dev/null 2>&1 || true   # registers it in accounts.md as ok
echo "Use it: spawn.sh … --account $id   (or --account auto)" >&2
