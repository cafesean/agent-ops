#!/usr/bin/env python3
"""send-lean-guard — PreToolUse(SendMessage) hook.

Why: a delivered message makes the receiver run a turn that re-reads its whole context (hundreds of thousands of
tokens per call). One measured day of real traffic: 3,053 messages = 6,580M tokens of wake turns vs 0.6M tokens of
message text. The text is not the cost, the wake is. So the guard stops the messages that wake a session for nothing:

  ack     the whole message is an acknowledgement ("ok", "ack", "thanks", "noted", "got it") — silence = received.
  noact   the sender says so itself: "no reply needed", "no action needed", "FYI only", "for your records".
  route   a who-is-who broadcast ("New chief = …", "new captain = …", "captain is now …"): the CHIEF / CAPTAIN
          files are the truth and every session re-reads them before it messages.

The deny says where the line goes instead: the sender's own task file `## Reports` (the receiver reads it when it
needs it). Nothing else is denied; no model call, no network.

Fails OPEN on any error. Escape: `# wake-ok: <reason>` in the message, or COS_ALLOW_LEAN_SEND=1.
Kill switch COS_SEND_LEAN_GUARD=0.
"""
import json
import os
import re
import sys

NOACT = re.compile(r"\b(no reply (?:is )?needed|no action (?:is )?needed|no reply required|no action required|"
                   r"nothing for you to do|fyi only|for your records)\b", re.I)
ROUTE = re.compile(r"^\s*(?:[\w.-]+\s*:\s*)?(?:new (?:[mx] )?(?:chief|captain)\b|(?:the )?[mx] (?:chief|captain) is now|"
                   r"(?:chief|captain) is now)", re.I)
ACK = re.compile(r"^\s*(?:[\w.-]+(?:\s*(?:→|->)\s*[\w.-]+)?\s*:\s*)?(?:ack(?:nowledged)?|ok(?:ay)?|thanks?|thank you|"
                 r"noted|got it|roger|received|understood|👍|✅)\b[\s.!,:;—-]*", re.I)
ROUTE_MAX = 400     # a longer message that opens with a routing line carries more; let it through
ACK_TAIL = 40       # chars allowed after the ack word before it counts as a real message


def verdict(text):
    s = (text or "").strip()
    if not s:
        return None
    if NOACT.search(s):
        return "noact"
    if len(s) < ROUTE_MAX and ROUTE.search(s):
        return "route"
    m = ACK.match(s)
    if m and len(s) - m.end() < ACK_TAIL:
        return "ack"
    return None


WHY = {
    "ack": "it is only an acknowledgement — silence means received",
    "noact": "it says itself that the receiver need not reply or act",
    "route": "it is a who-is-who broadcast — CHIEF / CAPTAIN / LEADS files are the truth and are re-read before messaging",
}


def main():
    if os.environ.get("COS_ALLOW_LEAN_SEND") == "1" or os.environ.get("COS_SEND_LEAN_GUARD") == "0":
        return
    data = json.load(sys.stdin)
    if data.get("tool_name") != "SendMessage":
        return
    ti = data.get("tool_input") or {}
    msg = ti.get("message") if "message" in ti else ti.get("content")
    if not isinstance(msg, str) or re.search(r"#\s*wake-ok:\s*\S", msg):
        return
    v = verdict(msg)
    if not v:
        return
    reason = (f"send-lean-guard: SendMessage denied — {WHY[v]}. Every message wakes the receiver into a turn that "
              f"re-reads its whole context (~445k tokens). Put the line in your task file ## Reports instead; the "
              f"receiver reads it when it needs it (worker-rules § Messaging). If the receiver must act on it now, "
              f"rewrite it as that action, or add `# wake-ok: <reason>`.")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass   # fail open
