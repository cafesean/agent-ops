#!/usr/bin/env bash
# Pane colour for a worker's Claude Code session.
# Sourced by spawn.sh. Local cmux panes only; --remote spawns get no colour.
#   cos_pane_color <parent goal ID> [task-file color: override]  → prints the colour name, or nothing
#   cos_send_pane_color <cmux bin> <workspace> <surface> <colour> → background: wait for the TUI, then `/color X` + Return
cos_pane_color() {
  local goal="$1" ovr="${2:-}"
  if [ -n "$ovr" ]; then
    case "$ovr" in red|blue|green|yellow|purple|orange|pink|cyan) printf '%s' "$ovr"; return 0;; *) echo "WARN: task color: '$ovr' is not a Claude Code colour (red blue green yellow purple orange pink cyan) — using the goal prefix" >&2;; esac
  fi
  # COS_PANE_COLORS="<prefix>=<colour>,…" — first prefix that starts the goal ID wins; unset/no match → no colour
  local pair pfx col
  IFS=, read -r -a _pc <<< "${COS_PANE_COLORS:-}"
  for pair in "${_pc[@]+"${_pc[@]}"}"; do
    pfx="${pair%%=*}"; col="${pair#*=}"
    [ -n "$pfx" ] && [ "$pfx" != "$pair" ] && case "$goal" in "$pfx"*) printf '%s' "$col"; return 0;; esac
  done
}
# /color sent while the first turn runs can sit in the input box or get lost. So: wait for the TUI (up to
# ${COS_COLOR_WAIT:-60}s), send, then poll read-screen for 'Session color set to: X' (up to ${COS_COLOR_VERIFY:-120}s
# over 3 sends); text stuck in the input box + pane idle → Return again; no confirmation → ctrl+u and resend.
# Optional 5th arg = spawn.sh focus snapshot (cos_focus_keep, addons/lib/cmux-equalize.sh). Backgrounded — never blocks.
cos_send_pane_color() {
  local cm="$1" ws="$2" surf="$3" color="$4" fsnap="${5:-}"
  (
    keep() { [ -z "$fsnap" ] || ! type cos_focus_keep >/dev/null 2>&1 || cos_focus_keep "$fsnap" "$ws" "$surf" "$1"; }
    rs() { "$cm" read-screen --workspace "$ws" --surface "$surf" --lines 60 2>/dev/null; }
    sk() { "$cm" send-key --workspace "$ws" --surface "$surf" "$1" >/dev/null 2>&1; }
    for i in $(seq 1 "${COS_COLOR_WAIT:-60}"); do
      rs | grep -qE 'bypass permissions|\? for shortcuts|esc to interrupt' && break
      sleep 1
    done
    keep claude-start
    per=$(( ${COS_COLOR_VERIFY:-120} / 3 )); [ "$per" -ge 5 ] || per=5
    for try in 1 2 3; do
      [ "$try" = 1 ] || sk ctrl+u
      "$cm" send --workspace "$ws" --surface "$surf" -- "/color $color" >/dev/null 2>&1
      sk return
      t=0
      while [ "$t" -lt "$per" ]; do
        sleep 3; t=$((t + 3)); scr=$(rs)
        printf '%s' "$scr" | grep -q "Session color set to: $color" && { keep color-send; exit 0; }
        if printf '%s' "$scr" | grep -qE "^[│|[:space:]]*>[[:space:]]*/color $color" \
           && ! printf '%s' "$scr" | grep -q 'esc to interrupt'; then sk return; fi
      done
    done
    exit 1
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
