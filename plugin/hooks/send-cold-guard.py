#!/usr/bin/env python3
"""send-cold-guard — PreToolUse(SendMessage) hook. Stops the chief from waking a cold session by message.
Active only when the agent-ops config exists (the cos-py.sh wrapper checks; it is the registered entry).

Denies a SendMessage to a LOCAL Claude session (a live ~/.claude/sessions/<pid>.json whose name = `to`) when
  (1) its last real turn (lib/lastturn.py) is >= COS_SEND_COLD_MIN (50) min ago — the 60-min prompt cache is about to
      die or dead, so the message pays a full cold reload — or
  (2) its task file ($COS_DIR/tasks/<name>.md) says status stopped / parked / done AND the session is not provably warm:
      its pid is dead (session file left behind) or its last turn is unknown. A LIVE pid with a last turn under the
      window is ALLOWED whatever the status (spawn.sh --continues marks a still-live predecessor stopped).
The deny names the continuity ladder: last turn < 50 min → `spawn.sh --task-file … --resume <uuid> --resume-prompt`;
colder → a fresh `spawn.sh --continues <name>` that starts from the session file.


Fails OPEN: any error, an unknown target (subagent, cloud session, another machine) → allow. Escape: `# cold-ok: <reason>`
in the message, or COS_ALLOW_COLD_SEND=1. Test overrides: COS_SESSIONS_DIR, COS_PROJECTS_DIR, COS_DIR.
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "skills", "chief-of-staff", "scripts", "lib")
sys.path.insert(0, LIB)
CLAUDE = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")


def cos_dir():
    if os.environ.get("COS_DIR"):
        return os.environ["COS_DIR"]
    env = os.path.join(HERE, "..", "skills", "chief-of-staff", "scripts", "cos-env.sh")
    out = subprocess.run(["bash", "-c", '. "$1" >/dev/null 2>&1; printf %s "$COS_DIR"', "_", env],
                         capture_output=True, text=True, timeout=3).stdout
    return out.strip()


def live_session(name):
    """(transcript path, sessionId, dead) for the local session named NAME. A live pid wins → (tr, sid, False); only a
    session file whose pid is dead → (None, sid, True); no session file at all → (None, None, False)."""
    sdir = os.environ.get("COS_SESSIONS_DIR") or os.path.join(CLAUDE, "sessions")
    pdir = os.environ.get("COS_PROJECTS_DIR") or os.path.join(CLAUDE, "projects")
    dead_sid = None
    for f in os.listdir(sdir):
        if not f.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(sdir, f)))
        except Exception:
            continue
        if d.get("name") != name:
            continue
        try:
            os.kill(int(d.get("pid")), 0)
        except Exception:
            dead_sid = dead_sid or d.get("sessionId") or "?"
            continue
        proj = (d.get("cwd") or "").replace("/", "-").replace(".", "-")
        return os.path.join(pdir, proj, f"{d.get('sessionId')}.jsonl"), d.get("sessionId"), False
    return None, dead_sid, dead_sid is not None


def task_status(name):
    d = cos_dir()
    p = os.path.join(d, "tasks", name + ".md") if d else ""
    if not p or not os.path.exists(p):
        return "", ""
    import tasks
    fm, _ = tasks.read(p)
    return str(fm.get("status") or "").lower(), p


def main():
    if os.environ.get("COS_ALLOW_COLD_SEND") == "1":
        return
    data = json.load(sys.stdin)
    if data.get("tool_name") != "SendMessage":
        return
    ti = data.get("tool_input") or {}
    to = re.sub(r"\s*\[[^\]]*\]\s*$", "", str(ti.get("to") or "")).strip()   # "name [ref]" → name
    msg = str(ti.get("message") or ti.get("content") or "")
    if not to or re.search(r"#\s*cold-ok:\s*\S", msg):
        return
    tr, sid, dead = live_session(to)
    cold = float(os.environ.get("COS_SEND_COLD_MIN") or 50)
    st, tp = task_status(to) if (tr or dead) else ("", "")
    ended = st in ("stopped", "parked", "done")
    why = []
    if dead:
        # no live pid: a known local session that is gone. Deny only when its task also says it ended (else fail open).
        if not ended:
            return
        mins = cold
        why.append(f"its process is dead and its task is {st}")
    elif not tr:
        return
    else:
        from lastturn import last_turn
        t, _ = last_turn(tr)
        mins = (time.time() - t) / 60 if t >= 0 else -1
        if mins >= cold:
            why.append(f"its last turn was {time.strftime('%H:%M', time.localtime(t))} ({mins:.0f} min ago, >= {cold:g}: "
                       f"prompt cache cold at 60)")
        elif ended and mins < 0:
            # last turn unknown → cannot prove it is warm; the stopped/parked/done status still denies.
            why.append(f"its task is {st} (stopped/handed off: the user's stop = stop) and its last turn is unknown")
        # live pid + last turn < window → ALLOW even when the task says stopped/parked/done.
        # spawn.sh --continues marks the predecessor stopped while the user may still be typing in it (or its subagents
        # keep stop.sh from ending it); the chief must still be able to tell that live session to wind down.
    if not why:
        return
    tf = tp or f"$COS_DIR/tasks/{to}.md"
    ladder = (f"Continuity ladder: last turn < 50 min → stop it, then `spawn.sh --task-file {tf} --resume {sid} "
              f"--resume-prompt '<the ask>'`; colder → a fresh successor `spawn.sh --continues {to}` (starts from its "
              f"session file).") if mins < cold else (
              f"Continuity ladder: colder than 50 min → a fresh successor `spawn.sh --continues {to}` that starts from "
              f"its session file — never wake the cold session.")
    reason = (f"send-cold-guard: SendMessage to {to} denied — " + "; ".join(why) + ". " + ladder +
              " Escape only if waking it is truly right: put `# cold-ok: <reason>` in the message.")
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
