#!/usr/bin/env python3
"""agent-budget-guard — PreToolUse(Agent|Task) hook. Caps subagent fan-out on an overloaded machine.
Active only when the agent-ops config exists (the cos-py.sh wrapper checks; it is the registered entry).

Denies a new subagent when
  (1) the load gate is OFFLOAD (skills/chief-of-staff/scripts/lib/loadgate.py: load5/cpu with
      hysteresis, ON > 1.2, OFF < 0.8 — same state file load-check.sh/spawn.sh use), or
(2) this machine already runs >= COS_MAX_LIVE_SUBAGENTS (default 8) live subagents.

Live subagent count — source: the subagent transcripts of LIVE sessions only.
  ~/.claude/sessions/<pid>.json (pid alive) → sessionId + cwd →
  ~/.claude/projects/<cwd slug>/<sessionId>/subagents/agent-*.jsonl.
  A transcript counts as live when it was written in the last COS_SUBAGENT_LIVE_WINDOW s (900)
  AND its last assistant record is not stop_reason=end_turn (a finished subagent always ends
  that way). Subagents run in-process, so there is no process to count; globbing every project
  costs >1 s, this path costs a few stats per live session.

Fails OPEN: any error → allow (no output). Escape: COS_ALLOW_SUBAGENT=1.
Test overrides: FAKE_LOAD5 / FAKE_NCPU (loadgate), FAKE_SUBAGENTS (count), COS_LOAD_STATE_FILE.
"""
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "skills", "chief-of-staff", "scripts", "lib"))

CLAUDE = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
WINDOW = 900


def slug(cwd):
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def subagent_live(path, now):
    try:
        st = os.stat(path)
        if now - st.st_mtime > WINDOW:
            return False
        with open(path, "rb") as f:
            f.seek(max(0, st.st_size - 16384))
            lines = f.read().decode("utf-8", "replace").splitlines()
        for line in reversed(lines):
            if '"assistant"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") != "assistant":
                continue
            return (d.get("message") or {}).get("stop_reason") != "end_turn"
        return True  # written recently, no assistant turn yet → just started
    except OSError:
        return False


def live_subagents():
    if os.environ.get("FAKE_SUBAGENTS"):
        return int(os.environ["FAKE_SUBAGENTS"])
    now = time.time()
    n = 0
    sdir = os.path.join(CLAUDE, "sessions")
    for name in os.listdir(sdir):
        if not name.endswith(".json"):
            continue
        try:
            os.kill(int(name[:-5]), 0)
        except (ValueError, ProcessLookupError):
            continue
        except PermissionError:
            pass
        try:
            with open(os.path.join(sdir, name)) as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        sid, cwd = d.get("sessionId"), d.get("cwd")
        if not sid or not cwd:
            continue
        adir = os.path.join(CLAUDE, "projects", slug(cwd), sid, "subagents")
        try:
            names = os.listdir(adir)
        except OSError:
            continue
        n += sum(1 for a in names if a.endswith(".jsonl") and subagent_live(os.path.join(adir, a), now))
    return n


def main():
    global WINDOW
    if os.environ.get("COS_ALLOW_SUBAGENT") == "1":
        return
    data = json.load(sys.stdin)
    if data.get("tool_name") not in ("Agent", "Task"):
        return
    WINDOW = int(os.environ.get("COS_SUBAGENT_LIVE_WINDOW") or 900)
    cap = int(os.environ.get("COS_MAX_LIVE_SUBAGENTS") or 8)

    offload, per = False, 0.0
    try:
        import loadgate
        offload, per, _l5, _n = loadgate.evaluate()
    except Exception:
        pass
    try:
        live = live_subagents()
    except Exception:
        live = -1  # unknown → don't gate on count
    if not offload and live < cap:
        return
    why = "load5/core %.2f%s, %s live subagents (cap %d)" % (
        per, " = OFFLOAD" if offload else "", "?" if live < 0 else live, cap)
    reason = ("Machine overloaded (%s) — wait, or run heavy work on the remote runner when configured. "
              "Finish with the subagents you have; retry after load5/core < %s and live < %d. "
              "(agent-budget-guard)"
              % (why, os.environ.get("COS_LOAD5_LEAVE") or "0.8", cap))
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
