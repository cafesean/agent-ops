#!/bin/bash
# agent-rule — UserPromptSubmit hook. A prompt that touches agents, roles, remix, storyboards, guardrails, refusals or
# rejects gets a two-line pointer to the no-refusals rule (skills/agent-no-refusals; p152 R12). The full paragraph is
# NOT injected, to keep session context small. Any other prompt: no output, exit 0. Never blocks.
INPUT=$(cat)
command -v python3 >/dev/null 2>&1 || exit 0
printf '%s' "$INPUT" | python3 -c '
import json, re, sys
try: p = json.load(sys.stdin).get("prompt") or ""
except Exception: sys.exit(0)
if not re.search(r"\b(agents?|roles?|remix|storyboards?|guardrails?|refus\w*|reject\w*)\b", p, re.I): sys.exit(0)
ctx = ("Agent work: R12 facts, not refusals; the single owner decides.\n"
       "Full rule: agent-no-refusals skill (agent-ops), and cadra:agents § first principle.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ctx}}, ensure_ascii=False))
'
exit 0
