"""heavy_classify — the heavy-command classifier heavy-cap-guard.py uses (one definition).
classify(argv) → (label|None, cwd override): tsc (non-watch, non-noEmit-incremental), next build, a full vitest/jest
run (no filter), turbo build/test/typecheck, pnpm/npm/yarn/bun test|typecheck|build. Pure functions, no I/O.
split_segments / tokens / strip_prefix turn a shell command line into argv lists (wrappers like time/nice dropped).
"""
import os
import re
import shlex

PMS = {"pnpm", "npm", "yarn", "bun"}
RUNNERS = {"npx", "pnpx", "bunx"}
WRAPPERS = {"rtk", "time", "nice", "nohup", "command", "exec", "caffeinate"}
# package scripts that are heavy when run without a filter
TYPECHECK = {"typecheck", "type-check", "check-types", "tsc"}
BUILD = {"build"}
TESTS = {"test", "test:unit", "test:run", "test:ci", "vitest"}
# pnpm/npm global flags that take a value
PM_VALUE_FLAGS = {"--filter", "-F", "--workspace"}
# vitest / test flags that take a value (so the value is not mistaken for a file filter)
TEST_VALUE_FLAGS = {
    "--dir", "--root", "-r", "--config", "-c", "--project", "--reporter", "--pool", "--shard",
    "--maxWorkers", "--minWorkers", "--environment", "--mode", "--outputFile", "--testTimeout",
    "--bail", "--retry",
}
FILTER_FLAGS = {"-t", "--testNamePattern", "--test-name-pattern", "--grep"}



def split_segments(cmd):
    """Split on && || ; | & and newlines, quote-aware. Returns list of (text, sep_before)."""
    segs, cur, i, q = [], [], 0, None
    while i < len(cmd):
        c = cmd[i]
        if q:
            cur.append(c)
            if c == "\\" and q == '"' and i + 1 < len(cmd):
                cur.append(cmd[i + 1]); i += 2; continue
            if c == q:
                q = None
            i += 1; continue
        if c in "'\"":
            q = c; cur.append(c); i += 1; continue
        if c == "\\" and i + 1 < len(cmd):
            cur.append(cmd[i:i + 2]); i += 2; continue
        if c == "#" and (not cur or cur[-1].isspace() or "".join(cur).strip() == ""):
            j = cmd.find("\n", i)
            i = len(cmd) if j < 0 else j
            continue
        if cmd.startswith("&&", i) or cmd.startswith("||", i):
            segs.append("".join(cur)); cur = []; i += 2; continue
        if c == "&" and ((cur and cur[-1] in "<>") or cmd.startswith("&>", i)):
            cur.append(c); i += 1; continue  # redirection (2>&1, &>file), not a separator
        if c in ";|&\n":
            segs.append("".join(cur)); cur = []; i += 1; continue
        cur.append(c); i += 1
    segs.append("".join(cur))
    return [s.strip() for s in segs if s.strip()]


def tokens(seg):
    try:
        t = shlex.split(seg)
    except ValueError:
        t = seg.split()
    out, skip = [], False
    for a in t:  # drop redirections: 2>&1, >file, > file, &>file, <in
        if skip:
            skip = False; continue
        m = re.match(r"^(\d*|&)(>>?|<)(&?\d*)?(.*)$", a)
        if m and (m.group(1) or m.group(2)):
            if not m.group(4) and not m.group(3):
                skip = True
            continue
        out.append(a)
    return out


def strip_prefix(t):
    """Drop env assignments and wrapper commands (rtk, time, env, timeout N...)."""
    while t:
        a = t[0]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a):
            t = t[1:]; continue
        if a in WRAPPERS:
            t = t[1:]
            if a == "rtk" and t and t[0] == "proxy":
                t = t[1:]
            while t and t[0].startswith("-") and a in ("nice", "caffeinate", "time"):
                t = t[1:]
            continue
        if a == "env":
            t = t[1:]
            while t and t[0].startswith("-"):
                t = t[1:]
            continue
        if a == "timeout":
            t = t[1:]
            while t and t[0].startswith("-"):
                t = t[1:]
            if t:
                t = t[1:]  # duration
            continue
        break
    return t


def has_filter(args):
    """True if the args narrow a test run: a positional (file/path/pattern) or -t/--testNamePattern."""
    skip = False
    for a in args:
        if skip:
            skip = False; continue
        if a == "--":
            continue
        base = a.split("=", 1)[0]
        if base in FILTER_FLAGS:
            return True
        if a.startswith("-"):
            if "=" not in a and a in TEST_VALUE_FLAGS:
                skip = True
            continue
        if a in ("run", "related"):  # vitest subcommands
            if a == "related":
                return True
            continue
        return True
    return False


def tsc_heavy(args):
    for a in args:
        if a in ("-v", "--version", "-h", "--help", "--init", "--showConfig"):
            return False
        if not a.startswith("-") and re.search(r"\.(c|m)?tsx?$", a) and not a.endswith(".json"):
            return False  # single-file tsc
    return True


def classify(t):
    """Return a short label if this argv is heavy, else None. Also returns a cwd override (pnpm -C)."""
    if not t:
        return None, None
    a0 = os.path.basename(t[0])
    rest = t[1:]
    if a0 in RUNNERS:
        rest = [x for x in rest if x not in ("-y", "--yes", "--no-install")]
        if not rest:
            return None, None
        return classify(rest)
    if a0 == "tsc":
        return ("tsc" if tsc_heavy(rest) else None), None
    if a0 == "next":
        return ("next build" if rest[:1] == ["build"] else None), None
    if a0 == "vitest":
        if rest[:1] and rest[0] in ("watch", "dev", "bench", "init", "list"):
            return None, None
        return (None if has_filter(rest) else "full vitest run"), None
    if a0 == "turbo":
        r = rest[1:] if rest[:1] == ["run"] else rest
        tasks = [x for x in r if not x.startswith("-")]
        if tasks and any(x in BUILD or x in TYPECHECK or x in TESTS for x in tasks):
            return "turbo " + " ".join(tasks), None
        return None, None
    if a0 in PMS:
        cwd = None
        i = 0
        while i < len(rest) and rest[i].startswith("-"):
            f = rest[i].split("=", 1)[0]
            if f in ("-C", "--dir", "--prefix"):
                if "=" in rest[i]:
                    cwd = rest[i].split("=", 1)[1]
                elif i + 1 < len(rest):
                    cwd = rest[i + 1]; i += 1
            elif f in PM_VALUE_FLAGS and "=" not in rest[i]:
                i += 1
            i += 1
        rest = rest[i:]
        if not rest:
            return None, cwd
        if rest[0] in ("exec", "dlx", "x"):
            return classify(rest[1:])[0], cwd
        if rest[0] in ("run", "run-script"):
            rest = rest[1:]
            while rest and rest[0].startswith("-"):
                rest = rest[1:]
            if not rest:
                return None, cwd
        script, sargs = rest[0], rest[1:]
        if script in ("tsc", "next", "vitest"):
            return classify(rest)[0], cwd
        if script in TYPECHECK:
            return "pnpm " + script if a0 == "pnpm" else a0 + " " + script, cwd
        if script in BUILD:
            return a0 + " " + script, cwd
        if script in TESTS:
            return (None if has_filter(sargs) else "full " + a0 + " " + script), cwd
        return None, cwd
    return None, None


