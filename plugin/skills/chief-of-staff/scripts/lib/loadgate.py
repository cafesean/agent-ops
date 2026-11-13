#!/usr/bin/env python3
"""loadgate — the ONE place the CPU-load OFFLOAD bit is decided.

Why: load1 swings too fast to gate on (a short dip lets a spawn through, then the machine saturates). So:
  - signal = load5 / ncpu (5-min average, a dip can't fake room)
  - hysteresis with a state file: OFFLOAD turns ON when load5/cpu > ENTER (1.2),
    and turns OFF only when load5/cpu < LEAVE (0.8). Between the two, the last state holds.

Used by: scripts/load-check.sh (→ spawn.sh / queue-run.sh) and hooks/agent-budget-guard.py.
Both read AND update the same state file, so whichever looks first moves the bit.

CLI:  loadgate.py           → prints "OFFLOAD <per_cpu> <load5> <ncpu>" or "OK <per_cpu> <load5> <ncpu>"
Env:
  COS_LOAD5_ENTER       default 1.2
  COS_LOAD5_LEAVE       default 0.8
  COS_LOAD_STATE_FILE   default $COS_DIR/load-offload.state, else ~/.claude/agent-ops/load-offload.state ("on"/"off")
  FAKE_LOAD5, FAKE_NCPU tests only (raw load5 and core count)
Any read error → treated as not overloaded (fail open), state unchanged.
"""
import os
import subprocess
import sys
import time

STATE = os.environ.get("COS_LOAD_STATE_FILE",
                       os.path.join(os.environ.get("COS_DIR") or os.path.expanduser("~/.claude/agent-ops"),
                                    "load-offload.state"))


def _f(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return float(default)


def load5_ncpu():
    if os.environ.get("FAKE_LOAD5"):
        l5 = float(os.environ["FAKE_LOAD5"])
    else:
        l5 = os.getloadavg()[1]
    if os.environ.get("FAKE_NCPU"):
        n = int(os.environ["FAKE_NCPU"])
    else:
        n = os.cpu_count() or int(subprocess.run(["sysctl", "-n", "hw.ncpu"], capture_output=True,
                                                 text=True, timeout=2).stdout.strip() or 1)
    return l5, max(n, 1)


def read_state():
    try:
        with open(STATE) as f:
            return f.read().split()[0] == "on"
    except (OSError, IndexError):
        return False


def write_state(on):
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        tmp = "%s.%d" % (STATE, os.getpid())
        with open(tmp, "w") as f:
            f.write("%s %d\n" % ("on" if on else "off", int(time.time())))
        os.replace(tmp, STATE)
    except OSError:
        pass


def evaluate():
    """Return (offload: bool, per_cpu: float, load5: float, ncpu: int). Updates the state file."""
    enter, leave = _f("COS_LOAD5_ENTER", 1.2), _f("COS_LOAD5_LEAVE", 0.8)
    try:
        l5, n = load5_ncpu()
    except Exception:
        return False, 0.0, 0.0, 0
    per = l5 / n
    prev = read_state()
    if per > enter:
        on = True
    elif per < leave:
        on = False
    else:
        on = prev
    if on != prev:
        write_state(on)
    return on, per, l5, n


if __name__ == "__main__":
    on, per, l5, n = evaluate()
    print("%s %.2f %.2f %d" % ("OFFLOAD" if on else "OK", per, l5, n))
    sys.exit(0)
