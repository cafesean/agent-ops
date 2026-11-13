#!/usr/bin/env python3
"""Last real turn of a Claude transcript (.jsonl) — the ONE source of session idle for every chief script.

Why not the transcript mtime: non-turn writes (api-request, attachment, summary...) bump it, so a
session idle for hours looks fresh. Idle = time since the newest entry with type "user" or "assistant" (its ISO-Z `timestamp`).
Reads the file tail backwards in chunks (never the whole transcript). No such entry → mtime, marked inexact.

  lastturn.py FILE [BEFORE]  → prints "<epoch> <exact 1|0>" ("-1 0" when the file is missing)
BEFORE (epoch): newest turn at or before it — spawn.sh replays a past spawn moment (COS_NOW) with it.
"""
import datetime as _dt, json, os, sys

CHUNK, MAXBYTES = 256 * 1024, 16 * 1024 * 1024


def _ts(s):
    try: return _dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception: return None


def last_turn(path, before=None):
    """(epoch, exact). exact False = fell back to mtime; (-1, False) = no file."""
    try: size, mt = os.path.getsize(path), os.path.getmtime(path)
    except OSError: return -1, False
    with open(path, "rb") as f:
        end, tail = size, b""
        while end > 0 and size - end < MAXBYTES:
            start = max(0, end - CHUNK)
            f.seek(start); buf = f.read(end - start) + tail
            lines = buf.split(b"\n")
            tail = lines.pop(0) if start > 0 else b""   # first line may be cut — carry it to the next chunk
            best = None
            for l in lines:
                if b'"timestamp"' not in l or (b'"user"' not in l and b'"assistant"' not in l): continue
                try: d = json.loads(l)
                except Exception: continue
                if isinstance(d, dict) and d.get("type") in ("user", "assistant") and not d.get("isApiErrorMessage"):
                    t = _ts(str(d.get("timestamp") or ""))
                    if t is not None and (before is None or t <= before) and (best is None or t > best): best = t
            if best is not None: return best, True
            end = start
    return mt, False


def last_ok_turn(path, before=None):
    """Epoch of the newest REAL model reply (type assistant, not isApiErrorMessage, not <synthetic>), or -1.
    This is when the prompt cache was last refreshed: a cron prompt (type user) or a synthetic
    `API Error: Can't reach the API server` entry does not touch the cache, so a session whose recent turns all ended
    in error entries is colder than its last turn says. Reads the tail backwards like last_turn."""
    try: size = os.path.getsize(path)
    except OSError: return -1
    with open(path, "rb") as f:
        end, tail = size, b""
        while end > 0 and size - end < MAXBYTES:
            start = max(0, end - CHUNK)
            f.seek(start); buf = f.read(end - start) + tail
            lines = buf.split(b"\n")
            tail = lines.pop(0) if start > 0 else b""
            best = None
            for l in lines:
                if b'"assistant"' not in l or b'"timestamp"' not in l: continue
                try: d = json.loads(l)
                except Exception: continue
                if not isinstance(d, dict) or d.get("type") != "assistant" or d.get("isApiErrorMessage"): continue
                if (d.get("message") or {}).get("model") == "<synthetic>": continue
                t = _ts(str(d.get("timestamp") or ""))
                if t is not None and (before is None or t <= before) and (best is None or t > best): best = t
            if best is not None: return best
            end = start
    return -1


def last_activity(path, before=None):
    """Epoch of the newest user/assistant entry of ANY kind, error entries included (a turn in flight or retrying
    after a connection error). The wake guard treats a session as busy while this is under 5 min old."""
    try: size, mt = os.path.getsize(path), os.path.getmtime(path)
    except OSError: return -1
    with open(path, "rb") as f:
        end, tail = size, b""
        while end > 0 and size - end < MAXBYTES:
            start = max(0, end - CHUNK)
            f.seek(start); buf = f.read(end - start) + tail
            lines = buf.split(b"\n")
            tail = lines.pop(0) if start > 0 else b""
            best = None
            for l in lines:
                if b'"timestamp"' not in l or (b'"user"' not in l and b'"assistant"' not in l): continue
                try: d = json.loads(l)
                except Exception: continue
                if isinstance(d, dict) and d.get("type") in ("user", "assistant"):
                    t = _ts(str(d.get("timestamp") or ""))
                    if t is not None and (before is None or t <= before) and (best is None or t > best): best = t
            if best is not None: return best
            end = start
    return mt


def idle_min(path, now=None):
    """(minutes, exact); (-1, False) when the file is missing."""
    import time
    t, exact = last_turn(path)
    if t < 0: return -1, False
    return max(0, int(((now or time.time()) - t) / 60)), exact


def label(t, now=None):
    """'HH:MM (N min ago)' for a last-turn epoch — the timing every chief view shows; '-' when unknown."""
    import time
    if t is None or t < 0: return "-"
    return f"{time.strftime('%H:%M', time.localtime(t))} ({max(0, int(((now or time.time()) - t) / 60))} min ago)"


def live_turns(claude_dir=None):
    """{session name: last-turn epoch} for every live local session (~/.claude/sessions/<pid>.json, pid alive)."""
    import glob
    d = os.path.expanduser(claude_dir or os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
    out = {}
    for f in glob.glob(os.path.join(d, "sessions", "*.json")):
        try:
            s = json.load(open(f)); os.kill(int(s.get("pid")), 0)
        except Exception: continue
        proj = (s.get("cwd") or "").replace("/", "-").replace(".", "-")
        t, _ = last_turn(os.path.join(d, "projects", proj, f"{s.get('sessionId')}.jsonl"))
        if s.get("name") and t >= 0: out[s["name"]] = max(t, out.get(s["name"], -1))
    return out


# Typed by the machine, not the user: spawn.sh's first prompt (spawn and --resume), the --continues first step, the
# chief's ⟦CK⟧ ping, cross-session messages and slash commands (/rename, /color). Matched on the start of the text
# and on the spawn prompt's own wording, so a changed prompt must keep one of these markers.
SPAWN_MARKERS = ("You are a worker session spawned by the chief of staff", "You are a worker spawned by the chief of staff",
                 "MANDATORY FIRST STEP: you continue worker",
                 "wake-guard: your prompt cache goes cold")   # wake-guard's park message, typed into the pane by the tick


def _machine_turn(txt):
    s = (txt or "").lstrip()
    if s.startswith(("⟦CK⟧", "<cross-session-message", "<command-name>", "<command-message>", "<task-notification", "<cos-msg",
                     "<system-reminder", "wake-guard:")): return True   # injected: ping, SendMessage, relayed message, background-task notice, park message
    return any(m in s[:2000] for m in SPAWN_MARKERS)


def last_human_turn(path, before=None):
    """Epoch of the newest turn the user TYPED (origin.kind == "human", not isMeta, not the spawn's first prompt), or -1.
    The reap gate: a worker that reported DONE may still be in use by the user; idle and the DONE line's age miss
    that. Reads the tail backwards like last_turn."""
    try: size = os.path.getsize(path)
    except OSError: return -1
    with open(path, "rb") as f:
        end, tail = size, b""
        while end > 0 and size - end < MAXBYTES:
            start = max(0, end - CHUNK)
            f.seek(start); buf = f.read(end - start) + tail
            lines = buf.split(b"\n")
            tail = lines.pop(0) if start > 0 else b""
            best = None
            for l in lines:
                if b'"human"' not in l: continue
                try: d = json.loads(l)
                except Exception: continue
                if not isinstance(d, dict) or d.get("type") != "user" or d.get("isMeta"): continue
                if (d.get("origin") or {}).get("kind") != "human" or d.get("parentUuid") is None: continue
                # checkin.sh's ⟦CK⟧ ping is typed into the pane, so it lands as origin "human"; it is the chief,
                # not the user (else every ping resets the 60-min gate and stop.sh refuses DONE workers)
                c = (d.get("message") or {}).get("content")
                txt = c if isinstance(c, str) else " ".join(x.get("text", "") for x in (c or []) if isinstance(x, dict))
                if _machine_turn(txt): continue
                t = _ts(str(d.get("timestamp") or ""))
                if t is not None and (before is None or t <= before) and (best is None or t > best): best = t
            if best is not None: return best
            end = start
    return -1


def live_human_turns(claude_dir=None):
    """{session name: epoch of the user's last typed turn} for every live local session."""
    import glob
    d = os.path.expanduser(claude_dir or os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
    out = {}
    for f in glob.glob(os.path.join(d, "sessions", "*.json")):
        try:
            s = json.load(open(f)); os.kill(int(s.get("pid")), 0)
        except Exception: continue
        proj = (s.get("cwd") or "").replace("/", "-").replace(".", "-")
        t = last_human_turn(os.path.join(d, "projects", proj, f"{s.get('sessionId')}.jsonl"))
        if s.get("name") and t >= 0: out[s["name"]] = max(t, out.get(s["name"], -1))
    return out


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--human-min":   # lastturn.py --human-min NAME → minutes since the user typed, -1
        import time
        t = live_human_turns().get(sys.argv[2], -1)
        print(-1 if t < 0 else int((time.time() - t) / 60)); sys.exit(0)
    t, e = last_turn(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else None)
    print(f"{int(t)} {int(e)}")
