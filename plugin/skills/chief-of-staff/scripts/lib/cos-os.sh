#!/usr/bin/env bash
# Source me. OS detection + portability helpers shared by cos-env.sh, doctor.sh and the hooks.
# No config, no writes, no network. Safe to source twice.
#   COS_OS      mac | linux | windows   (WSL counts as linux; Git Bash / MSYS / Cygwin = windows)
#   COS_WSL     1 inside WSL, else 0
#   COS_PYTHON  python 3 interpreter: python3, python, or "py -3" (config may override with a path)
#   cos_python ARGS…            run COS_PYTHON (handles the "py -3" form and paths with spaces)
#   cos_path P                  Windows path (C:\x or C:/x) → POSIX (/c/x via cygpath, /mnt/c/x via wslpath)
#   cos_path_list LIST          colon list → colon list of cos_path'd entries; tolerates C:\ drive colons
#   cos_source_config FILE      source a config, stripping CRLF line ends when present
if [ -z "${COS_OS:-}" ]; then
  case "$(uname -s 2>/dev/null)" in
    Darwin) COS_OS=mac;;
    MINGW*|MSYS*|CYGWIN*) COS_OS=windows;;
    *) COS_OS=linux;;
  esac
fi
if [ -z "${COS_WSL:-}" ]; then
  COS_WSL=0
  if [ "$COS_OS" = linux ] && [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then COS_WSL=1; fi
fi
if [ -z "${COS_PYTHON:-}" ]; then
  for _c in python3 python; do
    # verify it is really python 3 (the Windows Store "python3" alias exists but fails)
    if command -v "$_c" >/dev/null 2>&1 && "$_c" -c 'import sys; sys.exit(sys.version_info[0] < 3)' >/dev/null 2>&1; then
      COS_PYTHON="$_c"; break
    fi
  done
  if [ -z "${COS_PYTHON:-}" ] && command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then COS_PYTHON="py -3"; fi
  unset _c
fi
COS_PYTHON="${COS_PYTHON:-python3}"
export COS_OS COS_WSL COS_PYTHON

cos_python() {
  case "$COS_PYTHON" in
    "py -3"|"py") command py -3 "$@";;
    *) "$COS_PYTHON" "$@";;
  esac
}

cos_path() {  # only touches strings that look like Windows paths; everything else is printed unchanged
  case "$1" in
    [A-Za-z]:[\\/]*|*\\*)
      if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; return; fi
      if [ "${COS_WSL:-0}" = 1 ] && command -v wslpath >/dev/null 2>&1; then wslpath -u "$1" 2>/dev/null && return; fi
      printf '%s\n' "$1";;
    *) printf '%s\n' "$1";;
  esac
}

cos_path_list() {  # split on ':' but re-join a lone drive letter with the next part (C:\x, C:/x)
  local IFS=: out="" pend="" p l r
  # shellcheck disable=SC2086
  set -f; set -- $1; set +f
  for p in "$@"; do
    if [ -n "$pend" ]; then p="$pend:$p"; pend=""
    elif [ "${#p}" = 1 ] && case "$p" in [A-Za-z]) true;; *) false;; esac; then pend="$p"; continue
    fi
    case "$p" in
      *=*) l="${p%%=*}"; r="${p#*=}"; p="$(cos_path "$l")=$r";;   # LOCAL=REMOTE pairs: only LOCAL is a local path
      *) p="$(cos_path "$p")";;
    esac
    out="${out:+$out:}$p"
  done
  [ -z "$pend" ] || out="${out:+$out:}$pend"
  printf '%s\n' "$out"
}

cos_source_config() {  # tolerate a config saved with CRLF line ends (Windows editors)
  if grep -q "$(printf '\r')" "$1" 2>/dev/null; then
    eval "$(tr -d '\r' < "$1")"
  else
    # shellcheck disable=SC1090
    . "$1"
  fi
}

cos_wt_bin() {  # print the Windows Terminal binary when reachable (Git Bash or WSL interop), else exit 1
  [ "$COS_OS" = windows ] || [ "${COS_WSL:-0}" = 1 ] || return 1
  command -v wt.exe 2>/dev/null || command -v wt 2>/dev/null || return 1
}
