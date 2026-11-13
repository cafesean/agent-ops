#!/usr/bin/env python3
"""ask-guard — PreToolUse(Write|Edit|MultiEdit) hook. Keeps worker sessions autonomous: an ask the session could
answer itself, or one nobody can re-check, holds work up while the user is busy.

Denies a NEW ask added to a chief-of-staff task file ($COS_DIR/tasks/<name>.md — workers and the chief alike) when:
  nocheck — the new ask has no `check:` (shell command, run from $COS_DIR, exit 0 = no longer needed) or `evidence:`
           (what to look at) line: an ask nobody can re-check goes stale unseen (scripts/asks.py re-checks them).
  login  — its `what:` line is a sign-in / log-in / OAuth / "my browser tab" step → denied unless the line carries
           `user-only: <what you tried, why only the user can do it>` (a passkey or 2FA on the user's own device).
  config — its `what:` line is a dashboard / console / settings / env var / feature switch|flag / agent config /
           turn on / enable step → denied unless it names a hard gate (money, delete, customer message, ad account,
           legal, secret rotation, limits), asks the user to choose, or carries `user-only:`.
Only `what:` lines that are not already in the file (Write) or in old_string (Edit) count, so status edits on an existing
ask pass. Task dir: $COS_DIR/tasks ($COS_DIR from env, else from the agent-ops config via cos-env.sh); a file outside it
is never checked. Active only when the agent-ops config exists (the cos-py.sh wrapper checks; it is the registered
entry). Fails OPEN on any error. Kill switch COS_ASK_GUARD=0.
"""
import json
import os
import re
import subprocess
import sys

SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "skills", "chief-of-staff", "scripts")


def cos_dir():
    if os.environ.get("COS_DIR"):
        return os.environ["COS_DIR"]
    out = subprocess.run(["bash", "-c", '. "$1" >/dev/null 2>&1; printf %s "$COS_DIR"', "_",
                          os.path.join(SCRIPTS, "cos-env.sh")], capture_output=True, text=True, timeout=3).stdout
    return out.strip()


def is_task_file(path):
    if not path.endswith(".md"):
        return False
    d = cos_dir()
    if not d:
        return False
    return os.path.realpath(os.path.dirname(path)) == os.path.realpath(os.path.join(d, "tasks"))

WHAT = re.compile(r"^\s*-?\s*what:\s*(.+)$", re.M)
ESCAPE = re.compile(r"user-only:\s*\S", re.I)
LOGIN = re.compile(r"^\W*(one[- ](time )?|retry )?(google |github )?(sign|log)[ -]?(in|into)\b|\b(sign|log)[ -]?in(to)? once\b|"
                   r"\b(my|the) (browser|chrome) (tab|pane|window)\b|\bbrowsers (pane|workspace|tab)\b|"
                   r"\bin (my|the) (tab|pane)\b|\bneeds your (login|sign-?in)\b|\bno (prod |dev )?login\b(?! page)|"
                   r"\bsigned-in session\b", re.I)
CONFIG = re.compile(r"^\W*(turn on|enable|switch on|set up|create|tick|configure|give \S+ (dev |prod )?(key )?"
                    r"(permission|access)|send one test)\b|\b(env(ironment)? vars?|feature (switch|flag)|agent config)\b|"
                    r"\bsettings? ?(→|>|->)", re.I)
HARD_GATE = re.compile(r"(\$|\bmoney\b|\bpay|\bprice|\bpricing\b|\btop[ -]?up\b|\bcredits?\b|\bcard\b|\bbilling\b|"
                       r"\bdelete|\bcustomers?\b|\bad account|\blegal\b|\bsecret|\brotat|"
                       r"\blimits?\b)", re.I)
CHOICE = re.compile(r"\b(how many|which one|pick (a|one)|ok to ship|or keep)\b", re.I)


def whats(text):
    return {m.strip() for m in WHAT.findall(text or "")}


def new_whats(tool, ti):
    if tool == "Write":
        try:
            old = open(ti.get("file_path") or "").read()
        except Exception:
            old = ""
        return whats(ti.get("content")) - whats(old)
    edits = ti.get("edits") if tool == "MultiEdit" else [ti]
    out = set()
    for e in edits or []:
        out |= whats(e.get("new_string")) - whats(e.get("old_string"))
    return out


CHECKKEY = re.compile(r"^\s*-?\s*(check|evidence):\s*\S", re.M)


def new_lines(tool, ti):
    if tool == "Write":
        try:
            old = set(open(ti.get("file_path") or "").read().split("\n"))
        except Exception:
            old = set()
        return "\n".join(l for l in (ti.get("content") or "").split("\n") if l not in old)
    edits = ti.get("edits") if tool == "MultiEdit" else [ti]
    out = []
    for e in edits or []:
        old = set((e.get("old_string") or "").split("\n"))
        out += [l for l in (e.get("new_string") or "").split("\n") if l not in old]
    return "\n".join(out)


def verdict(what):
    if ESCAPE.search(what):
        return None
    if LOGIN.search(what):
        return "login"
    if CONFIG.search(what) and not HARD_GATE.search(what) and not CHOICE.search(what):
        return "config"
    return None


def main():
    if os.environ.get("COS_ASK_GUARD") == "0":
        return
    data = json.load(sys.stdin)
    tool = data.get("tool_name")
    ti = data.get("tool_input") or {}
    if tool not in ("Write", "Edit", "MultiEdit") or not is_task_file(ti.get("file_path") or ""):
        return
    nw = new_whats(tool, ti)
    hits = [(w, v) for w in nw for v in [verdict(w)] if v]
    nl = new_lines(tool, ti)
    if not hits and nw and not CHECKKEY.search(nl):
        reason = ("ask-guard: every new ask needs a re-check line, or it keeps asking after it stops mattering. Add "
                  "ONE of: `check: \"<shell cmd, run from $COS_DIR, exit 0 = ask no longer needed, 1 = still needed>\"` "
                  "(e.g. gh pr view N --json state -q .state | grep -q MERGED) or `evidence: \"<what to look at to see it is "
                  "still true>\"`. Asks unchecked for 24 h drop out of the needs-the-user list (scripts/asks.py).")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": reason}}))
        return
    if not hits:
        return
    w, kind = hits[0]
    reason = (f"ask-guard: this ask is a {kind} step — the session's own work, not the user's (chief-of-staff "
              f"SKILL.md § Autonomy). Ask: {w[:160]!r}. Do it with the access the session already has: a logged-in "
              f"browser profile, a stored credential, a CLI that is already authenticated. Ask the user only for what "
              f"physically needs them (passkey/2FA on their device) or a hard gate: money / customer message / delete / "
              f"ad account / legal / secret rotation / limits. Tried and still blocked? Put `user-only: <what you "
              f"tried, why only the user>` in the what: line.")
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
