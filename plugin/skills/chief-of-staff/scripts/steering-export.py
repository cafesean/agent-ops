#!/usr/bin/env python3
"""steering-export.py — every word the user gave a session, verbatim, for its successor (no LLM).

Every message from the user (what they care about, problems they caught, feedback) must reach the successor. agent-ops:session-update writes 'User Steering' from the model's memory and drops items; this script reads
the transcript instead. Runs from every handover path (context-handoff-guard, stop.sh HANDOFF, spawn.sh --continues),
so it never depends on the model remembering.

Kept, in order, each with its local time:
  - typed  : a turn the user typed (origin.kind "human", not isMeta, not machine text — lastturn.py's detection);
  - relayed: a peer message (SendMessage / queued cross-session message) that quotes the user: "User:", "the user
             says", "User 14:0x adds …", or the same with any name in COS_USER_NAMES (comma list, default empty).
Skipped: tool results, the spawn first prompt, ⟦CK⟧ pings, slash commands, hook text, system reminders.

Usage: steering-export.py NAME [--transcript PATH]... [--out PATH] [--quiet]
  NAME        the session name (customTitle). Transcript: --transcript, else the live registry, else the newest
              ~/.claude/projects/*/*.jsonl whose customTitle is NAME (21 days, newest first).
  --out       default $COS_DIR/steering/NAME.md
Prints "<path>\t<items>" and exits 0; exit 3 = no transcript found (nothing written).
"""
import glob, json, os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
from lastturn import _machine_turn  # noqa: E402  (one human-turn detection for every chief script)

_WHO = "|".join(["(the )?user", "owner"] + [re.escape(n.strip()) for n in (os.environ.get("COS_USER_NAMES") or "").split(",") if n.strip()])
RELAY = re.compile(r"\b(" + _WHO + r")\b(\s+\d{1,2}:\d[\dx]\w*)?\s*(:|says|said|adds|added|asks|asked|wants|wrote|replied|"
                   r"answered|approved|decided|told)", re.I)
REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
SKIP_START = ("<local-command", "<command-name>", "<command-message>", "<bash-", "Caveat:", "[Request interrupted",
              "<task-notification", "<system-reminder")


def _text(content):
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text":
            out.append(b.get("text") or "")
        elif b.get("type") == "image":
            out.append("[image]")
        elif b.get("type") == "tool_result":
            return None   # a tool result line is never steering
    return "\n".join(out)


def _local(ts):
    try:
        import datetime as dt
        t = dt.datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp()
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(t))
    except Exception:
        return "?"


def _peer_body(txt):
    """Body of a cross-session message wrapper, else the text itself."""
    m = re.search(r"<cross-session-message[^>]*>\s*(.*?)\s*(</cross-session-message>|$)", txt, re.S)
    return m.group(1) if m else txt


def _peer_from(txt):
    m = re.search(r'from-name="([^"]+)"', txt or "")
    return m.group(1) if m else "peer"


def items(path):
    """[(local time, kind, source, text)] in transcript order, de-duplicated."""
    out, seen = [], set()
    with open(path, "rb") as f:
        for raw in f:
            if b'"user"' not in raw and b'queued_command' not in raw and b'queue-operation' not in raw:
                continue
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(d, dict) or d.get("isSidechain"):
                continue
            ts, origin, mid = d.get("timestamp"), d.get("origin") or {}, False
            if d.get("type") == "attachment":
                a = d.get("attachment") or {}
                p = a.get("prompt") if a.get("type") == "queued_command" else None
                if not isinstance(p, str) or "<cross-session-message" not in p:
                    continue
                kind, src, txt = "relayed", _peer_from(p), _peer_body(p)
            elif d.get("type") == "user":
                txt = _text((d.get("message") or {}).get("content"))
                if txt is None:
                    continue
                if origin.get("kind") == "peer" or "<cross-session-message" in txt[:400]:
                    kind, src = "relayed", origin.get("name") or _peer_from(txt)
                    txt = origin.get("body") or _peer_body(txt)
                elif "<teammate-message" in txt[:600]:   # agent-team teammate: no origin, never the user typing
                    m = re.search(r'<teammate-message[^>]*teammate_id="([^"]+)"[^>]*>\s*(.*?)\s*(</teammate-message>|$)', txt, re.S)
                    kind, src, txt = "relayed", (m.group(1) if m else "teammate"), (m.group(2) if m else txt)
                elif d.get("isMeta"):
                    continue
                elif origin.get("kind") != "human":   # lastturn.py's rule: only origin "human" is the user typing
                    continue
                else:
                    kind, src = "typed", "user"
            elif d.get("type") == "queue-operation":   # text typed while the session was busy
                c = d.get("content")
                if d.get("operation") != "enqueue" or not isinstance(c, str):
                    continue
                kind, src, txt, mid = "typed", "user", c, True
            else:
                continue
            txt = REMINDER.sub("", txt or "").strip()
            if not txt or txt.lstrip().startswith(SKIP_START):
                continue
            if kind == "typed" and _machine_turn(txt):
                continue
            if kind == "relayed" and not RELAY.search(txt):
                continue
            key = (kind, txt)
            if key in seen:
                continue
            seen.add(key)
            out.append((_local(ts), kind, src, txt + (" (typed mid-turn)" if mid else "")))
    return out


def find_transcript(name):
    needle = f'"customTitle":"{name}"'.encode()
    d = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
    for f in glob.glob(os.path.join(d, "sessions", "*.json")):   # live registry first: no scan
        try:
            s = json.load(open(f))
        except Exception:
            continue
        if s.get("name") == name:
            proj = (s.get("cwd") or "").replace("/", "-").replace(".", "-")
            p = os.path.join(d, "projects", proj, f"{s.get('sessionId')}.jsonl")
            if os.path.exists(p):
                return p
    cut = time.time() - 21 * 86400
    files = [p for p in glob.glob(os.path.join(d, "projects", "*", "*.jsonl")) if os.path.getmtime(p) >= cut]
    for p in sorted(files, key=os.path.getmtime, reverse=True):
        try:
            with open(p, "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        i = data.rfind(b'"customTitle":"')
        if i >= 0 and data.startswith(needle, i):
            return p
    return None


def render(name, paths, its):
    typed = sum(1 for i in its if i[1] == "typed")
    lines = [f"# Steering — {name}", "",
             f"{len(its)} items ({typed} typed by the user, {len(its) - typed} relayed by peers), verbatim, oldest first.",
             f"Exported {time.strftime('%Y-%m-%d %H:%M')} by steering-export.py from: " + ", ".join(f"`{p}`" for p in paths),
             "Successor: give every item a row in your task file — done (evidence) / open (next step) / rule (where "
             "filed) / unclear (ask the predecessor, then the user).", ""]
    for n, (t, kind, src, txt) in enumerate(its, 1):
        lines += [f"## {n} · {t} · {'the user (typed)' if kind == 'typed' else f'relayed by {src}'}", ""]
        lines += ["> " + l if l else ">" for l in txt.split("\n")]
        lines.append("")
    return "\n".join(lines)


def main(argv):
    if not argv or argv[0].startswith("-"):
        print(__doc__, file=sys.stderr)
        return 2
    name, paths, out, quiet = argv[0], [], None, False
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--transcript" and i + 1 < len(argv):
            paths.append(argv[i + 1]); i += 2
        elif a == "--out" and i + 1 < len(argv):
            out = argv[i + 1]; i += 2
        elif a == "--quiet":
            quiet = True; i += 1
        else:
            print(f"unknown argument {a}", file=sys.stderr)
            return 2
    paths = [p for p in paths if p and os.path.exists(p)]
    if not paths:
        p = find_transcript(name)
        paths = [p] if p else []
    if not paths:
        print(f"steering-export: no transcript for {name}", file=sys.stderr)
        return 3
    its = [x for p in paths for x in items(p)]
    if not out:
        cos = os.environ.get("COS_DIR")
        if not cos:
            import subprocess
            try:
                cos = subprocess.run(["bash", "-c", '. "$1" >/dev/null 2>&1; printf %s "$COS_DIR"', "_",
                                      os.path.join(HERE, "cos-env.sh")], capture_output=True, text=True,
                                     timeout=5).stdout.strip()
            except Exception:
                cos = ""
            cos = cos or os.path.expanduser("~/agent-ops/state")
        out = os.path.join(cos, "steering", f"{name}.md")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(render(name, paths, its))
    os.replace(tmp, out)
    if not quiet:
        print(f"{out}\t{len(its)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
