#!/usr/bin/env bash
# check-plugin.sh — read-only lint of a Claude Code plugin directory.
# Usage: bash check-plugin.sh <plugin-dir> [<marketplace-root>]
#   <plugin-dir>        dir holding .claude-plugin/plugin.json
#   <marketplace-root>  dir holding .claude-plugin/marketplace.json (default: nearest ancestor that has one)
# Prints PASS/WARN/FAIL lines; exit 1 on any FAIL, 2 on usage error. No writes, no network.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_LIB="$HERE/../../chief-of-staff/scripts/lib/cos-os.sh"
# shellcheck source=/dev/null
[ -f "$OS_LIB" ] && . "$OS_LIB"
if ! command -v cos_python >/dev/null 2>&1; then
  cos_path() { printf '%s\n' "$1"; }
  cos_python() { python3 "$@"; }
fi
[ $# -ge 1 ] || { echo "usage: check-plugin.sh <plugin-dir> [<marketplace-root>]" >&2; exit 2; }
plugin="$(cos_path "$1")"
mkt="${2:+$(cos_path "$2")}"
[ -d "$plugin" ] || { echo "FAIL not a directory: $plugin" >&2; exit 2; }
cos_python "$HERE/check_plugin.py" "$plugin" ${mkt:+"$mkt"}
