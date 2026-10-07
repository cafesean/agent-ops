#!/usr/bin/env bash
# bump.sh — bump a plugin version across plugin.json, its marketplace.json entry and package.json (when present).
# Usage: bash bump.sh <repo-root> <patch|minor|major|X.Y.Z> [--plugin NAME] [--write]
# Dry run unless --write. Never commits, tags or pushes. No network.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_LIB="$HERE/../../chief-of-staff/scripts/lib/cos-os.sh"
# shellcheck source=/dev/null
[ -f "$OS_LIB" ] && . "$OS_LIB"
if ! command -v cos_python >/dev/null 2>&1; then
  cos_path() { printf '%s\n' "$1"; }
  cos_python() { python3 "$@"; }
fi
[ $# -ge 2 ] || { echo "usage: bump.sh <repo-root> <patch|minor|major|X.Y.Z> [--plugin NAME] [--write]" >&2; exit 2; }
root="$(cos_path "$1")"; shift
cos_python "$HERE/bump.py" "$root" "$@"
