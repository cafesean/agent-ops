#!/usr/bin/env python3
"""heavy-cap-guard — PreToolUse(Bash) hook. Caps concurrent heavy local jobs (a few parallel tsc runs at ~1 GB
each are enough to saturate a laptop).

Denies a heavy local job (tsc, vitest, jest, next build, pnpm/npm/yarn/bun test|typecheck|build,
turbo build/test/typecheck) when >= COS_MAX_HEAVY_LOCAL (default 2) heavy job processes already
run on this machine. Applies everywhere (not only under the heavy-guard scope root) and even with mini-run-guard's
`# local-ok:` — local-ok says WHERE it must run, not that the machine has room.
`mini-run …` commands pass (they run on the remote runner). Only Claude tool calls reach this hook,
so dev servers the user starts by hand are never blocked.
Active only when the agent-ops config exists (the .sh wrapper checks; the wrapper is the registered entry).

Command classification is mini-run-guard.py's classify() (one definition), plus bare `jest`.
Running-job count: ONE `ps -Axo args=` pass (comm= is cut at 16 chars on macOS, so argv is used).
A job = a process whose argv[0] or script argv[1] is tsc/tsgo/vitest/jest/turbo, or next + build.
Worker children (vitest/jest/next workers) are not counted; watch modes and turbo daemon not either.

Fails OPEN: any error → allow. Escapes: `# heavy-ok: <reason>` in the command, COS_ALLOW_HEAVY_CAP=1.
Test override: FAKE_HEAVY=<n> replaces the ps count.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

HEAVY_BIN = {"tsc", "tsgo", "vitest", "jest", "turbo"}
SCRIPT_RE = re.compile(r"/(typescript/(bin/tsc|lib/tsc\.js)|\.bin/(tsc|tsgo|vitest|jest|turbo|next)"
                       r"|vitest/vitest\.mjs|jest(-cli)?/bin/jest(\.js)?|next/dist/bin/next"
                       r"|turbo/bin/turbo|@typescript/native-preview/bin/tsgo(\.js)?)$")


def load_classifier():
    spec = importlib.util.spec_from_file_location("mrg", os.path.join(HERE, "mini-run-guard.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def job_kind(argv):
    """Return a label if this process argv is a heavy job (not a worker child), else None."""
    if not argv:
        return None
    a0 = os.path.basename(argv[0])
    rest = argv[1:]
    if a0 in ("node", "bun") or a0.startswith("node"):
        if not rest or not SCRIPT_RE.search(rest[0]):
            return None
        a0, rest = os.path.basename(rest[0]).split(".")[0], rest[1:]
    if a0 == "typescript":
        a0 = "tsc"
    if a0 not in HEAVY_BIN and a0 != "next":
        return None
    if a0 == "next":
        return "next build" if "build" in rest[:2] else None
    if a0 in ("tsc", "tsgo") and any(x in ("-w", "--watch") for x in rest):
        return None
    if a0 == "vitest" and rest[:1] and rest[0] in ("watch", "dev"):
        return None
    if a0 == "turbo" and not any(re.search(r"(^|[:#])(build|test|typecheck|type-check|check-types)$", x) for x in rest):
        return None  # turbo dev / daemon / --version are not build jobs
    return a0


def running_heavy():
    if os.environ.get("FAKE_HEAVY"):
        return int(os.environ["FAKE_HEAVY"]), []
    out = subprocess.run(["ps", "-Axo", "args="], capture_output=True, text=True, timeout=2).stdout
    jobs = []
    for line in out.splitlines():
        k = job_kind(line.split())
        if k:
            jobs.append(k)
    return len(jobs), jobs


def cmd_heavy(cmd, mrg):
    for seg in mrg.split_segments(cmd):
        t = mrg.strip_prefix(mrg.tokens(seg))
        if not t:
            continue
        label = mrg.classify(t)[0]
        if label:
            return label
        if os.path.basename(t[0]) == "jest" or (t[0] in mrg.RUNNERS and t[1:2] == ["jest"]):
            args = t[1:] if t[0] == "jest" else t[2:]
            if not mrg.has_filter(args):
                return "full jest run"
    return None


def main():
    if os.environ.get("COS_ALLOW_HEAVY_CAP") == "1":
        return
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not cmd.strip() or re.search(r"#\s*heavy-ok:\s*\S", cmd):
        return
    if re.search(r"(^|[\s;&|(/])mini-run(\s|$)", cmd):
        return
    label = cmd_heavy(cmd, load_classifier())
    if not label:
        return
    cap = int(os.environ.get("COS_MAX_HEAVY_LOCAL") or 2)
    n, jobs = running_heavy()
    if n < cap:
        return
    reason = ("%d heavy jobs already running here (%s) — wait, or use mini-run when the remote runner is configured. "
              "Your command: %s. Escape only if it truly must run now: `# heavy-ok: <reason>`. "
              "(heavy-cap-guard, cap COS_MAX_HEAVY_LOCAL)"
              % (n, ", ".join(jobs) or "count override", label))
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
