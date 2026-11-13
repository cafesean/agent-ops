#!/bin/bash
# agent-refusal-warn — PreToolUse hook on Edit, Write, MultiEdit. Warns (never blocks) when an agent-touching file gets
# refusal wording: the no-refusals rule says tools return facts and the owner decides. Other files: no output, exit 0.
INPUT=$(cat)
command -v python3 >/dev/null 2>&1 || exit 0
printf '%s' "$INPUT" | python3 -c '
import json, re, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
ti = d.get("tool_input") or {}
path = ti.get("file_path") or ""
if not re.search(r"(agent|role|tool-authoring|review)", path, re.I):
    sys.exit(0)
tool = d.get("tool_name") or ""
if tool == "MultiEdit": new = " ".join((e.get("new_string") or "") for e in ti.get("edits") or [])
elif tool == "Write": new = ti.get("content") or ""
else: new = ti.get("new_string") or ""
hits = sorted(set(m.lower() for m in re.findall(r"\b(refus\w*|rejects?|rejected|blocks?|blocked)\b", new, re.I)))
# G7: a numeric threshold in agent code or copy is a hard-coded decision (warn only; docs may quote thresholds)
thresholds = re.findall(r"[<>]=?\s*\d+(?:\.\d+)?", new)
if not hits and not thresholds: sys.exit(0)
parts = []
if hits: parts.append("G4 refusal wording (" + ", ".join(hits) + ")")
if thresholds: parts.append("G7 numeric threshold (" + ", ".join(sorted(set(thresholds))[:5]) + ")")
msg = ("Agent-file finding: " + "; ".join(parts) + ". The no-refusals rule: tools return facts "
       "{status, reason, options|next} and the owner decides; no hard-coded decision. Rewrite as a fact or a named owner decision. Warning only.")
print(json.dumps({"systemMessage": msg, "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": msg}}, ensure_ascii=False))
'
exit 0
