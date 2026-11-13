#!/usr/bin/env python3
"""context-handoff-guard — Stop hook. A long-running session (the chief or a worker) hands over to a successor before
its context runs out, instead of dying mid-work.
Active only when the agent-ops config exists (the cos-py.sh wrapper checks; it is the registered entry).

At the end of a turn, reads the session transcript's latest assistant `usage` (input + cache read + cache creation =
the context the model saw). At or above the session's handover point it blocks the stop ONCE per session with the handover steps: Resume Here in the session file,
start the successor the usual way (spawn.sh --continues / a new chief), report the HANDOFF line, then stop.
Handover point: task frontmatter `handoff_at`, else the hard cap (spawn.sh stamps the role default from
scripts/lib/handoff.py); after call 20 the
session's own reload size is stored as `handoff_r` and `handoff_at` recomputed when it differs > 25 %. The env var
COS_CONTEXT_HANDOFF_TOKENS (default 800000) stays the fallback and the ceiling. On block it also exports the user's
words verbatim (scripts/steering-export.py). Applies to every session that loads this plugin (the chief, workers,
headless sessions). Task dir: $COS_DIR/tasks ($COS_DIR from env, else from the agent-ops config via cos-env.sh).

Fails OPEN: any error, a missing transcript, or `stop_hook_active` → allow. Marker per session id in
~/.claude/agent-ops/.context-handoff/ so it fires once. Test overrides: COS_CONTEXT_HANDOFF_TOKENS,
COS_CONTEXT_MARK_DIR.
"""
import json
import os
import subprocess
import sys

SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "skills", "chief-of-staff", "scripts")
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))


def context_tokens(path):
    """Context size of the newest assistant turn, or None."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        f.seek(max(0, size - 2_000_000))
        lines = f.read().decode("utf-8", "replace").splitlines()
    for line in reversed(lines):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        u = (d.get("message") or {}).get("usage") if d.get("type") == "assistant" else None
        if isinstance(u, dict):
            return sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens",
                                                       "cache_creation_input_tokens"))
    return None


def session_name(path):
    """customTitle of the transcript (the session name), or ''."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        i = data.rfind(b'"customTitle":"')
        return data[i + 15:data.find(b'"', i + 15)].decode("utf-8", "replace") if i >= 0 else ""
    except OSError:
        return ""


def export_steering(name, path):
    """Every word the user gave this session → $COS_DIR/steering/<name>.md (scripts/steering-export.py). '' on failure."""
    import subprocess
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "skills", "chief-of-staff", "scripts",
                          "steering-export.py")
    try:
        r = subprocess.run([sys.executable, script, name, "--transcript", path], capture_output=True, text=True,
                           timeout=30)
        return r.stdout.strip().split("\t")[0] if r.returncode == 0 else ""
    except Exception:
        return ""


def task_file(name):
    cos = cos_dir()
    p = os.path.join(cos, "tasks", f"{name}.md")
    return p if name and os.path.exists(p) else ""


def cos_dir():
    if os.environ.get("COS_DIR"):
        return os.environ["COS_DIR"]
    try:
        out = subprocess.run(["bash", "-c", '. "$1" >/dev/null 2>&1; printf %s "$COS_DIR"', "_",
                              os.path.join(SCRIPTS, "cos-env.sh")], capture_output=True, text=True, timeout=3).stdout
        return out.strip() or os.path.expanduser("~/agent-ops/state")
    except Exception:
        return os.path.expanduser("~/agent-ops/state")


def early_calls(path, n):
    """Context of the first n API calls (deduped by message id), or fewer when the session is younger."""
    out, seen = [], set()
    with open(path, "rb") as f:
        for raw in f:
            if b'"usage"' not in raw or b'"assistant"' not in raw:
                continue
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            m = d.get("message") or {}
            u = m.get("usage")
            if d.get("type") != "assistant" or d.get("isSidechain") or not isinstance(u, dict) or m.get("id") in seen:
                continue
            seen.add(m.get("id"))
            out.append(sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens",
                                                       "cache_creation_input_tokens")))
            if len(out) >= n:
                break
    return out


def limit_for(name, path, tfile):
    """(handoff_at, role). Task `handoff_at` (spawn.sh stamps the role default), else the hard cap; once a session
    with `handoff_at` passes call 20 its own R
    (context at call 20) is stored as `handoff_r` and, when it differs from the role's R by > 25 %, `handoff_at`
    is recomputed (lib/handoff.py). Never above the hard cap."""
    import handoff as H
    fm = H._fm(tfile) if tfile else {}
    role = H.role_of(name, fm)
    if tfile and str(fm.get("handoff_at") or "").strip() and not str(fm.get("handoff_r") or "").strip():
        calls = early_calls(path, H.R_CALL)
        if len(calls) >= H.R_CALL:
            R, ramp = calls[-1], sum(calls)
            sets = ["handoff_r", str(R)]
            if abs(R - H.ROLES[role]["R"]) > H.RECOMPUTE_DIFF * H.ROLES[role]["R"]:
                fm["handoff_at"] = str(H.recompute(role, R, ramp))
                sets += ["handoff_at", fm["handoff_at"]]
            subprocess.run([sys.executable, os.path.join(SCRIPTS, "lib", "tasks.py"), "set", tfile, *sets],
                           capture_output=True, timeout=10)
    return H.handoff_at(fm, name), role


def main():
    try:
        ev = json.load(sys.stdin)
    except ValueError:
        return 0
    if ev.get("stop_hook_active"):
        return 0
    path, sid = ev.get("transcript_path") or "", ev.get("session_id") or "unknown"
    if not path or not os.path.exists(path):
        return 0
    name = os.environ.get("COS_WORKER") or session_name(path)
    try:
        limit, role = limit_for(name, path, task_file(name))
    except Exception:
        limit, role = int(os.environ.get("COS_CONTEXT_HANDOFF_TOKENS") or 800000), "?"
    used = context_tokens(path)
    if used is None or used < limit:
        return 0
    marks = os.path.expanduser(os.environ.get("COS_CONTEXT_MARK_DIR") or "~/.claude/agent-ops/.context-handoff")
    mark = os.path.join(marks, sid)
    if os.path.exists(mark):
        return 0
    os.makedirs(marks, exist_ok=True)
    open(mark, "w").write(str(used))
    steer = export_steering(name or sid, path)
    name = os.environ.get("COS_WORKER") or ""
    steer_txt = (f" The user's words to this session are exported verbatim to `{steer}`: before step 3, mark each item's "
                 "status in your session file (done + evidence / open + next step / rule + where filed)." if steer else "")
    who = (f"You are worker `{name}`: start the successor with `spawn.sh --task-file <your task file> --continues "
           f"{name}` (it reads your session file)." if name else
           "If you are the chief: your successor is a new chief session that reads STATE.md, then Outstanding.md and "
           "your handoff file (SKILL.md → Handoff (new chief session)); spawn it, or tell the user in one line to start it.")
    reason = (f"CONTEXT HANDOVER: this session's context is {used:,} tokens (≥ its handover point {limit:,}, role {role}: lib/handoff.py). Hand over "
              "now, before it runs out: 1) write a Resume Here block in your session file (/agent-ops:session-update); 2) " + who + " (if the successor's task file already exists, never write it: read its status and message the successor) 3) append a `status: HANDOFF "
              "<time> … successor: <name>` line to your task file; 4) stop."+ steer_txt)
    print(json.dumps({"decision": "block", "reason": reason}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
