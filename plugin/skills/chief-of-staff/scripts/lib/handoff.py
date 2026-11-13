#!/usr/bin/env python3
"""handoff.py — the context size at which a session hands over (`handoff_at`), per session, from measured cost.

Cost model: every API call re-reads the whole cached context; a
handover writes the successor's reloaded context R into a fresh 1-hour cache once (20x a cache read) and spends its
first 20 calls reloading. Cheapest point: H = R + sqrt(2·k·R·g), k = 20 + reload_reads / R, g = growth per call.

  ROLES          measured medians per role + the approved handover point `at`
  role_of(name, fm)  lead | chief | captain | multi | tester | builder  (multi = builder with task `lanes:` 2 or more)
  default_at(name)       the role's `at` (spawn.sh stamps it as task `handoff_at`)
  handoff_at(fm, name)   task frontmatter `handoff_at` (never above the hard cap); none → the hard cap
  recompute(role, R, ramp)   per-session point once the successor's own R (context at call 20) is measured: the role's
                 cheapest point moved by the measured R, plus the margin the approved number keeps over the cheapest.
                 FLOOR roles never drop below their approved point.
Hard cap: COS_CONTEXT_HANDOFF_TOKENS (default 800000) — fallback and ceiling.
Lead names: a name matching `-lead(-|$)` or the regex in COS_HANDOFF_LEAD_RE (default empty) is role lead.
CLI: handoff.py at NAME [TASKFILE] → tokens · handoff.py default NAME [TASKFILE] → the role's point · handoff.py role NAME
"""
import math, os, re, sys

K_WRITE = 20.0
R_CALL = 20
# R, g, ramp = measured medians of successor sessions; at = approved handover point
ROLES = {
    "lead":    dict(R=131_000, g=1_500, ramp=2_200_000, at=700_000),
    "chief":   dict(R=147_000, g=1_100, ramp=2_500_000, at=700_000),
    "captain": dict(R=131_000, g=1_300, ramp=2_100_000, at=700_000),
    "multi":   dict(R=132_000, g=1_400, ramp=2_200_000, at=700_000),   # builder with several lanes (task `lanes:` >= 2)
    "tester":  dict(R=125_000, g=1_200, ramp=2_100_000, at=700_000),
    "builder": dict(R=132_000, g=1_400, ramp=2_200_000, at=700_000),

}
FLOOR = {"lead", "chief", "captain", "multi", "builder", "tester"}   # the re-measure never pulls a point below its approved `at`
RECOMPUTE_DIFF = 0.25   # recompute only when the measured R differs from the role's R by more than this share


def cap():
    try:
        return int(os.environ.get("COS_CONTEXT_HANDOFF_TOKENS") or 800_000)
    except ValueError:
        return 800_000


def role_of(name, fm=None):
    fm = fm or {}
    if "-chief" in name:
        return "chief"
    if "release-captain" in name or "-captain" in name:
        return "captain"
    extra = os.environ.get("COS_HANDOFF_LEAD_RE") or ""
    if re.search(r"-lead(-|$)", name) or (extra and re.search(extra, name)):
        return "lead"
    if re.search(r"tester|e2e|-test(-|$)", name):
        return "tester"
    try:
        if int(str(fm.get("lanes") or "0").strip() or 0) >= 2:
            return "multi"
    except ValueError:
        pass
    return "builder"


def best(R, g, ramp):
    k = K_WRITE + ramp / R
    return R + math.sqrt(2 * k * R * g)


def recompute(role, R, ramp=None):
    """handoff_at from a measured R (and the measured reload reads, when known)."""
    r = ROLES[role]
    margin = r["at"] - best(r["R"], r["g"], r["ramp"])
    h = best(R, r["g"], ramp if ramp else r["ramp"] * R / r["R"]) + margin
    if role in FLOOR:
        h = max(h, r["at"])
    return int(min(cap(), max(R + 50_000, round(h, -4))))


def default_at(name, fm=None):
    """The role's approved point — spawn.sh stamps it into a new task file as `handoff_at`."""
    return min(cap(), ROLES[role_of(name, fm)]["at"])


def handoff_at(fm, name):
    """Task `handoff_at` (capped); a task without one keeps the hard cap, so an upgrade never makes every live
    session hand over at once. A FLOOR role never reads below its approved point, so a `lanes:` line added after
    spawn takes effect without a re-stamp."""
    try:
        v = int(str((fm or {}).get("handoff_at") or "").strip() or 0)
    except ValueError:
        v = 0
    if v:
        role = role_of(name, fm)
        if role in FLOOR:
            v = max(v, ROLES[role]["at"])
    return min(cap(), v) if v else cap()


def _fm(path):
    """Frontmatter of a task file. Reads the whole file: a fixed window can miss `handoff_r` in a long frontmatter,
    and the guard then recomputes handoff_at on every turn."""
    try:
        head = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return {}
    if not head.startswith("---"):
        return {}
    head = head.split("\n---", 1)[0]
    return dict(re.findall(r"^([a-z_]+):\s*\"?([^\"\n]*?)\"?\s*$", head, re.M))


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 2 and a[0] == "at":
        print(handoff_at(_fm(a[2]) if len(a) > 2 else {}, a[1]))
    elif len(a) >= 2 and a[0] == "default":
        print(default_at(a[1], _fm(a[2]) if len(a) > 2 else None))
    elif len(a) == 2 and a[0] == "role":
        print(role_of(a[1]))
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
