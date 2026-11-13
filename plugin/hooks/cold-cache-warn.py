#!/usr/bin/env python3
"""cold-cache-warn — UserPromptSubmit hook, any session (not only workers).

Warns the user (systemMessage, shown to the user) when they type into a session whose prompt cache is cold: the next turn
re-reads the whole context uncached. Warn only — never blocks, never edits the prompt. Silent when the cache is
warm, the session has no real reply yet, or anything fails. Kill switch COS_COLD_WARN=0. Threshold COS_WG_COLD_MIN (60).
Active only when the agent-ops config exists (the cos-py.sh wrapper checks; it is the registered entry).
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "skills", "chief-of-staff", "scripts", "lib"))


def main():
    if os.environ.get("COS_COLD_WARN") == "0":
        return
    import time
    import lastturn as LT
    tr = json.load(sys.stdin).get("transcript_path") or ""
    ok = LT.last_ok_turn(tr)
    if ok < 0:
        return
    age = int((time.time() - ok) / 60)
    if age < int(os.environ.get("COS_WG_COLD_MIN", "60")):
        return
    tokens = ""
    try:  # context size from the last real reply's usage
        with open(tr, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 400_000)); tail = f.read().split(b"\n")
        for l in reversed(tail):
            if b'"assistant"' in l and b'"cache_read_input_tokens"' in l and b"<synthetic>" not in l:
                u = (json.loads(l).get("message") or {}).get("usage") or {}
                n = sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                if n:
                    tokens = f" (~{n // 1000}k tokens)"
                break
    except Exception:
        pass
    print(json.dumps({"systemMessage": f"Cache is cold ({age} min since the last model reply): this turn re-reads the whole context{tokens} "
                      f"uncached. For a small question, a fresh session reading the Resume Here file is cheaper."}))


try:
    main()
except Exception:
    pass
