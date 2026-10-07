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
# Sent BEFORE the pane's first turn can finish: the first prompt is claude's argv, so the TUI is already working when this
# lands — /color is typed as soon as the input box is up. Polls up to ${COS_COLOR_WAIT:-60}s; never blocks spawn.sh.
cos_send_pane_color() {
  local cm="$1" ws="$2" surf="$3" color="$4" i
  (
    for i in $(seq 1 "${COS_COLOR_WAIT:-60}"); do
      "$cm" read-screen --workspace "$ws" --surface "$surf" 2>/dev/null | grep -qE 'bypass permissions|\? for shortcuts|esc to interrupt' && break
      sleep 1
    done
    "$cm" send --workspace "$ws" --surface "$surf" -- "/color $color" >/dev/null 2>&1
    "$cm" send-key --workspace "$ws" --surface "$surf" return >/dev/null 2>&1
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
