#!/usr/bin/env python3
"""worktree-owner — PostToolUse hook (Bash, EnterWorktree). Stamps every git worktree a chief-spawned worker
creates with its owner, so stop.sh can verify teardown from git instead of from report text.

- Owner = $COS_WORKER (spawn.sh exports it; subagents inherit the parent's env, so their worktrees get the
  parent's name). Not a worker → exit at once.
- Bash: each `git [-C dir] worktree add ... <path>` in the command; the path resolves against `-C`, else the
  last `cd <dir>` before it, else the hook's cwd. EnterWorktree: every existing path in tool_input/tool_response.
- Writes `<worktree admin dir>/cos-owner` (line 1 = owner, line 2 = ISO time, line 3 = session id) and appends
  the admin dir to `<dirname $COS_HEARTBEAT_DIR>/.worktrees/<owner>` (stop.sh reads both).
- Zero stdout, always exit 0 (fails open). Kill switch COS_WORKTREE_OWNER=0.
"""
import json, os, re, shlex, subprocess, sys, time

OWNER = os.environ.get("COS_WORKER", "")
if os.environ.get("COS_WORKTREE_OWNER", "1") == "0" or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", OWNER or "-"):
    sys.exit(0)


def admin_dir(path):
    """The worktree's admin dir (<common>/worktrees/<id>), or None when path is not a linked worktree."""
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--absolute-git-dir"], capture_output=True, text=True, timeout=5)
    except Exception:
        return None
    d = r.stdout.strip()
    return d if r.returncode == 0 and "/worktrees/" in d and os.path.isfile(os.path.join(d, "gitdir")) else None


def stamp(path, sid):
    d = admin_dir(path)
    if not d:
        return
    with open(os.path.join(d, "cos-owner"), "w") as f:
        f.write(f"{OWNER}\n{time.strftime('%Y-%m-%dT%H:%M:%S')}\n{sid}\n")
    hb = os.environ.get("COS_HEARTBEAT_DIR", "")
    if hb:
        reg = os.path.join(os.path.dirname(hb.rstrip("/")), ".worktrees")
        os.makedirs(reg, exist_ok=True)
        with open(os.path.join(reg, OWNER), "a") as f:
            f.write(d + "\n")


# options of `git worktree add` that take a value
VALOPT = {"-b", "-B", "--reason", "--orphan"}


def bash_paths(cmd, cwd):
    """Yield absolute paths of worktrees created by `git worktree add` in a Bash command string."""
    for seg in re.split(r"&&|\|\||;|\n|\|", cmd):
        try:
            tok = shlex.split(seg)
        except ValueError:
            continue
        if not tok:
            continue
        if tok[0] == "cd" and len(tok) > 1:
            cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(tok[1])))
            continue
        if "git" not in tok:
            continue
        i = tok.index("git")
        base, j = cwd, i + 1
        while j < len(tok) and tok[j].startswith("-"):
            if tok[j] == "-C" and j + 1 < len(tok):
                base = os.path.normpath(os.path.join(base, os.path.expanduser(tok[j + 1])))
                j += 2
            elif tok[j] == "-c":
                j += 2
            else:
                j += 1
        if tok[j:j + 2] != ["worktree", "add"]:
            continue
        k = j + 2
        while k < len(tok):
            t = tok[k]
            if t in VALOPT:
                k += 2
                continue
            if t.startswith("-"):
                k += 1
                continue
            yield os.path.normpath(os.path.join(base, os.path.expanduser(t)))
            break


def strings(o):
    if isinstance(o, str):
        yield o
    elif isinstance(o, dict):
        for v in o.values():
            yield from strings(v)
    elif isinstance(o, list):
        for v in o:
            yield from strings(v)


try:
    ev = json.load(sys.stdin)
    tool = ev.get("tool_name", "")
    sid = ev.get("session_id", "")
    cwd = ev.get("cwd") or os.getcwd()
    if tool == "Bash":
        cmd = (ev.get("tool_input") or {}).get("command", "")
        if re.search(r"\bworktree\s+add\b", cmd):
            for p in bash_paths(cmd, cwd):
                stamp(p, sid)
    elif tool == "EnterWorktree":
        seen = set()
        for s in strings([ev.get("tool_input"), ev.get("tool_response")]):
            for p in re.findall(r"/[^\s\"'`,;:]+", s):
                p = p.rstrip(".)")
                if p not in seen and os.path.isfile(os.path.join(p, ".git")):
                    seen.add(p)
                    stamp(p, sid)
except Exception:
    pass
sys.exit(0)
