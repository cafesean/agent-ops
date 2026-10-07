#!/bin/bash
# cos-heartbeat — PostToolUse + Stop hook. A chief-spawned worker (env COS_WORKER, set by spawn.sh's launch
# script) touches $COS_HEARTBEAT_DIR/<worker> on every tool call and every turn end. Zero model tokens: no
# stdout, always exit 0. checkin.sh reads the mtime and pings (⟦CK⟧) only workers silent > 30 min.
# Any other session: exits at the first line. Arms only in sessions started after the plugin update.
[ -n "${COS_WORKER:-}" ] && [ -n "${COS_HEARTBEAT_DIR:-}" ] || exit 0
case "$COS_WORKER" in *[!a-z0-9-]*) exit 0;; esac
mkdir -p "$COS_HEARTBEAT_DIR" 2>/dev/null && : > "$COS_HEARTBEAT_DIR/$COS_WORKER" 2>/dev/null
exit 0
