#!/usr/bin/env python3
"""ctx.py — context used by every live Claude session on this machine, as % of the real window.

The chief checks worker context on every sweep, so a worker hands over before it runs out.
For each live session (sessions.sh --tsv) find its newest transcript (.jsonl holding
"customTitle":"NAME" under ~/.claude/projects/*), read the LAST assistant usage line and print
input + cache_read + cache_creation tokens. Window = COS_CTX_WINDOW (default 1_000_000, a 1M-context model).
Flags are against each session's OWN handover point `at`
(task `handoff_at`, else its role default — lib/handoff.py): >= 90% of `at` WARN, >= `at` NEEDS-YOU (hand over now).
Usage: ctx.py [--tsv]   (tests: COS_CTX_SESSIONS_TSV = a sessions.sh --tsv dump, CLAUDE_CONFIG_DIR = transcripts)
"""
import glob, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
import handoff as H  # noqa: E402

WINDOW = int(os.environ.get("COS_CTX_WINDOW", "1000000"))
def _cos_dir():
    try:
        out = subprocess.run(["bash", "-c", '. "$1" >/dev/null 2>&1; printf %s "$COS_DIR"', "_", os.path.join(HERE, "cos-env.sh")],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return out or os.path.expanduser("~/agent-ops/state")
    except Exception:
        return os.path.expanduser("~/agent-ops/state")


COS = os.environ.get("COS_DIR") or _cos_dir()


def point(name):
    """The session's handover point in tokens."""
    return H.handoff_at(H._fm(os.path.join(COS, "tasks", f"{name}.md")), name)


def flag_of(u, at):
    if u is None:
        return ""
    return "NEEDS-YOU" if u >= at else ("WARN" if u >= 0.9 * at else "")

def live_sessions():
    if os.environ.get("COS_CTX_SESSIONS_TSV"):   # tests: a sessions.sh --tsv dump
        out = open(os.environ["COS_CTX_SESSIONS_TSV"]).read()
    else:
        out = subprocess.run([os.path.join(HERE, "sessions.sh"), "--tsv"], capture_output=True, text=True).stdout
    rows = [l.split("\t") for l in out.strip().split("\n")[1:] if l.strip()]
    return [(r[1], r[4]) for r in rows if len(r) > 4 and r[0] == "live"]

def last_usage(data):
    for line in reversed(data[-3_000_000:].split(b"\n")):
        if b'"usage"' not in line:
            continue
        try:
            us = (json.loads(line).get("message") or {}).get("usage")
        except Exception:
            continue
        if us:
            return us.get("input_tokens", 0) + us.get("cache_read_input_tokens", 0) + us.get("cache_creation_input_tokens", 0)
    return None

def main():
    want = dict(live_sessions())
    proj = os.path.join(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"), "projects")
    files = sorted(glob.glob(os.path.join(proj, "*", "*.jsonl")), key=os.path.getmtime, reverse=True)[:200]
    found = {}
    for f in files:
        if len(found) == len(want):
            break
        try:
            data = open(f, "rb").read()
        except OSError:
            continue
        i = data.rfind(b'"customTitle":"')
        if i < 0:
            continue
        t = data[i + 15:data.find(b'"', i + 15)].decode(errors="replace")
        if t in want and t not in found:
            found[t] = last_usage(data)
    tsv = "--tsv" in sys.argv
    if tsv:
        print("name\tidle_m\tctx_tokens\tctx_pct\tflag\thandoff_at")
    for name, idle in want.items():
        u = found.get(name)
        pct = None if u is None else round(100 * u / WINDOW)
        at = point(name)
        flag = flag_of(u, at)
        if tsv:
            print(f"{name}\t{idle}\t{u if u is not None else ''}\t{pct if pct is not None else ''}\t{flag}\t{at}")
        else:
            c = "?" if u is None else f"{pct}% ({u // 1000}k)"
            print(f"{name:30} idle {idle:>4}m  ctx {c:>12}  at {at // 1000}k  {flag}")

if __name__ == "__main__":
    main()
