#!/bin/bash
# cos-ck — UserPromptSubmit hook. When the prompt is exactly ⟦CK⟧ (the chief's check-in ping) in a chief-spawned
# worker (env COS_WORKER), inject the check-in protocol read FRESH from skills/chief-of-staff/protocols/ck.md,
# with the worker's report file, inbox tag and the current time filled in — so the ping is 5 characters and the
# worker answers with one report line, not a recap. Any other prompt or session: no output, exit 0.
[ -n "${COS_WORKER:-}" ] || exit 0
INPUT=$(cat)
case "$INPUT" in *'⟦CK⟧'*) ;; *) exit 0;; esac
# COS_PYTHON fallbacks (python3 → python → py -3); no python at all → stay silent, never block the user
. "$(dirname "$0")/../skills/chief-of-staff/scripts/lib/cos-os.sh" 2>/dev/null || exit 0
printf '%s' "$INPUT" | cos_python -c '
import json, os, sys, datetime
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
if (d.get("prompt") or "").strip() != "⟦CK⟧": sys.exit(0)
p = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[1]))), "skills", "chief-of-staff", "protocols", "ck.md")
try: t = open(p, encoding="utf-8").read()
except OSError: sys.exit(0)
t = t.split("<!-- protocol -->", 1)[-1].strip()
w = os.environ["COS_WORKER"]
for k, v in {"{worker}": w, "{report}": os.environ.get("COS_REPORT_FILE") or f"your inbox/{w}.md",
             "{tag}": os.environ.get("COS_TAG") or f"[?] {w}", "{now}": datetime.datetime.now().strftime("%Y-%m-%d %H:%M")}.items():
    t = t.replace(k, v)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": t}}, ensure_ascii=False))
' "$0"
