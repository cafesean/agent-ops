#!/usr/bin/env bash
# Shared cmux layout helpers for spawn.sh, stop.sh and checkin.sh. Always return 0 —
# a spawn or stop never fails over layout.
#
# HARD RULE: NEVER move an existing surface. move-surface / drag-surface-to-split rebuild the
# pane (new pane ref) and wipe its scrollback. Layout is decided ONCE, before a pane exists, by picking which pane to
# split and in which direction; after that only the equalize RPC (resizes dividers, keeps every pane) runs.
#
#   cos_equalize <workspace:N>             # workspace.equalize_splits RPC only + WARN if a pane < COS_MIN_COLS
#   plan=$(cos_grid_plan <workspace:N>)    # BEFORE creating a pane: "<surface_ref> <right|down>", empty = no fit
#   new-split "${plan#* }" --surface "${plan% *}" --workspace <ws> --focus false ...   (spawn.sh)

COS_CMUX="${COS_CMUX_BIN:-/Applications/cmux.app/Contents/Resources/bin/cmux}"

cos_ws_id() {   # workspace:N → UUID (the RPC silently ignores a ref and hits the focused workspace)
  CMUX_QUIET=1 "$COS_CMUX" workspace list --json 2>/dev/null | jq -r --arg r "$1" '.workspaces[] | select(.ref == $r) | .id'
}

cos_equalize() {
  local ws="${1:-}" id reply got min
  [ -n "$ws" ] && [ -x "$COS_CMUX" ] && command -v jq >/dev/null 2>&1 || return 0
  id=$(cos_ws_id "$ws"); [ -n "$id" ] || { echo "WARN: equalize: no workspace $ws" >&2; return 0; }
  reply=$(CMUX_QUIET=1 "$COS_CMUX" rpc workspace.equalize_splits "{\"workspace_id\":\"$id\"}" 2>&1)
  got=$(printf '%s' "$reply" | jq -r '.workspace_ref // empty' 2>/dev/null)
  [ "$got" = "$ws" ] || { echo "WARN: equalize $ws hit '${got:-?}': $reply" >&2; return 0; }
  min=$(CMUX_QUIET=1 "$COS_CMUX" rpc pane.list "{\"workspace_id\":\"$id\"}" 2>/dev/null | jq '[.panes[]? | .columns | numbers] | min // 0')
  if [ "${min:-0}" -gt 0 ] && [ "$min" -lt "${COS_MIN_COLS:-80}" ]; then
    echo "WARN: $ws narrowest pane $min cols < ${COS_MIN_COLS:-80} — too many panes; not rearranging (moves wipe scrollback), close one" >&2
  fi
  echo "$ws equalized (min ${min:-?} cols)"
  return 0
}

# Pick the split BEFORE the pane exists. Min width = COS_MIN_COLS (80); if the whole screen can't hold two
# columns of that, 60. Prefer splitting RIGHT the widest pane whose halves stay >= min (fills width first);
# else DOWN on the tallest pane whose halves keep >= 8 rows. Neither fits → empty (caller WARNs, uses default).
cos_grid_plan() {
  local ws="${1:-}" id
  [ -n "$ws" ] && [ -x "$COS_CMUX" ] && command -v jq >/dev/null 2>&1 || return 0
  id=$(cos_ws_id "$ws"); [ -n "$id" ] || return 0
  CMUX_QUIET=1 "$COS_CMUX" rpc pane.list "{\"workspace_id\":\"$id\"}" 2>/dev/null | jq -r --argjson min "${COS_MIN_COLS:-80}" '
    [.panes[] | select(.columns > 0 and .selected_surface_ref != null)
     | {s: .selected_surface_ref, c: .columns, r: .rows, x: (.pixel_frame.x // 0), y: (.pixel_frame.y // 0)}] as $p
    | if ($p | length) == 0 then empty else
        (((.container_frame.width // 0) / (.panes[0].cell_width_px // 7)) | floor) as $total
        | (if $total >= 2 * $min then $min else 60 end) as $m
        | ([$p[] | select(((.c - 1) / 2 | floor) >= $m)] | sort_by(-.c, -.r, .x, .y)) as $right
        | ([$p[] | select(((.r - 1) / 2 | floor) >= 8)] | sort_by(-.r, -.c, .x, .y)) as $down
        | if ($right | length) > 0 then $right[0].s + " right"
          elif ($down | length) > 0 then $down[0].s + " down"
          else empty end
      end' 2>/dev/null
  return 0
}
