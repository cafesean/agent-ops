#!/usr/bin/env python3
"""Tests for lib/handoff.py + hooks/context-handoff-guard.py + scripts/ctx.py (per-session handover point) and
scripts/steering-export.py (every word the user gave a session, verbatim, no LLM). Synthetic transcripts with tool
noise, pings, hooks and peer relays. Run:
    python3 plugin/tests/steering-line.test.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "skills", "chief-of-staff", "scripts")
TMP = tempfile.mkdtemp(prefix="steer-")
os.environ["COS_DIR"] = os.path.join(TMP, "cos")
os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(TMP, "claude")
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, file))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


SE = load("steering_export", "steering-export.py")


def ts(sec):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(sec))


def user(text, sec, origin="human", meta=False, side=False, **kw):
    d = {"type": "user", "isMeta": meta, "isSidechain": side, "origin": {"kind": origin, **kw}, "parentUuid": "p",
         "timestamp": ts(sec), "message": {"role": "user", "content": text}}
    if origin is None:
        d.pop("origin")
    return json.dumps(d)


T0 = 1_762_700_000
PEER_USER = 'a-chief-1109, User 14:0x adds to PHASE 2: every message from the user must reach the successor.'
PEER_WRAP = ('Another Claude session sent a message:\n<cross-session-message from="uds:/tmp/x.sock" '
             f'from-name="a-chief-1109" from-mode="bypass">\n{PEER_USER}\n</cross-session-message>')
LINES = [
    json.dumps({"type": "custom-title", "customTitle": "a-test-lead-3", "sessionId": "s1"}, separators=(",", ":")),
    user("Style: caveman. You are a worker spawned by the chief of staff. Task file: /x.md. Its body is your charter",
         T0),
    user("Why are you deploying to dev?\n<system-reminder>STYLE REMINDER: caveman</system-reminder>", T0 + 60),
    user("⟦CK⟧ a-chief-1109 check-in: append one status line", T0 + 120),
    user([{"type": "tool_result", "tool_use_id": "t1", "content": "User: fake words inside a tool result"}], T0 + 130,
         origin=None),
    user('Another Claude session sent a message:\n<teammate-message teammate_id="parts0ee" color="purple">\nstall '
         'verdict: NOT a bug\n</teammate-message>', T0 + 135, origin=None),
    user("Stop hook feedback: CONTEXT HANDOVER", T0 + 140, origin=None, meta=True),
    user("<command-name>/color</command-name>\n<command-message>color</command-message>", T0 + 150),
    json.dumps({"type": "attachment", "timestamp": ts(T0 + 200), "attachment": {"type": "queued_command",
                                                                                "prompt": PEER_WRAP.split("\n", 1)[1]}}),
    user(PEER_WRAP, T0 + 210, origin="peer", meta=True, name="a-chief-1109", body=PEER_USER),
    user('Another Claude session sent a message:\n<cross-session-message from-name="a-builder-2">\nbuild green, '
         'hash abc1234\n</cross-session-message>', T0 + 220, origin="peer", meta=True, name="a-builder-2",
         body="build green, hash abc1234"),
    user("sidechain words", T0 + 230, side=True),
    user([{"type": "text", "text": "Look at this"}, {"type": "image", "source": {}}], T0 + 240),
    user("I already said undo. Zero credits issues on dev", T0 + 300),
]


def write_transcript():
    proj = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects", "-tmp-x")
    os.makedirs(proj, exist_ok=True)
    p = os.path.join(proj, "s1.jsonl")
    open(p, "w").write("\n".join(LINES) + "\n")
    return p


class SteeringExport(unittest.TestCase):
    def setUp(self):
        self.path = write_transcript()

    def test_keeps_only_the_user(self):
        its = SE.items(self.path)
        texts = [t for _, _, _, t in its]
        self.assertEqual(texts, ["Why are you deploying to dev?", PEER_USER, "Look at this\n[image]",
                                 "I already said undo. Zero credits issues on dev"])
        self.assertEqual([k for _, k, _, _ in its], ["typed", "relayed", "typed", "typed"])
        self.assertEqual(its[1][2], "a-chief-1109")

    def test_cli_finds_transcript_by_title_and_writes_file(self):
        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, "steering-export.py"), "a-test-lead-3"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        out, n = r.stdout.strip().split("\t")
        self.assertEqual(n, "4")
        body = open(out).read()
        self.assertIn("## 1 · ", body)
        self.assertIn("> Why are you deploying to dev?", body)
        self.assertNotIn("STYLE REMINDER", body)
        self.assertNotIn("fake words inside a tool result", body)

    def test_missing_transcript_exit_3(self):
        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, "steering-export.py"), "a-nobody-1"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 3)

    def test_spawn_prompt_not_human_in_lastturn(self):
        import lastturn
        self.assertTrue(lastturn._machine_turn("Style: x. You are a worker spawned by the chief of staff. Task"))


class HandoffGuard(unittest.TestCase):
    def test_guard_exports_steering_on_block(self):
        path = write_transcript()
        with open(path, "a") as f:
            f.write(json.dumps({"type": "assistant", "timestamp": ts(T0 + 400), "message": {
                "id": "a1", "usage": {"input_tokens": 1, "cache_read_input_tokens": 900_000}}}) + "\n")
        env = dict(os.environ, COS_CONTEXT_MARK_DIR=os.path.join(TMP, "marks"), COS_WORKER="a-test-lead-3")
        r = subprocess.run([sys.executable, os.path.join(HERE, "..", "hooks", "context-handoff-guard.py")],
                           input=json.dumps({"transcript_path": path, "session_id": "s1"}), capture_output=True,
                           text=True, env=env)
        out = json.loads(r.stdout)
        self.assertEqual(out["decision"], "block")
        self.assertIn("steering/a-test-lead-3.md", out["reason"])
        self.assertTrue(os.path.exists(os.path.join(os.environ["COS_DIR"], "steering", "a-test-lead-3.md")))


HO = load("handoff_lib", os.path.join("lib", "handoff.py"))


def transcript(name, ctxs, title=True):
    """A transcript for session `name` whose API calls ran at the given context sizes."""
    proj = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects", "-tmp-h")
    os.makedirs(proj, exist_ok=True)
    p = os.path.join(proj, f"{name}.jsonl")
    L = [json.dumps({"type": "custom-title", "customTitle": name}, separators=(",", ":"))] if title else []
    L += [json.dumps({"type": "assistant", "timestamp": ts(T0 + i), "message": {"id": f"{name}-{i}", "usage": {
        "input_tokens": 1, "cache_read_input_tokens": c - 1}}}) for i, c in enumerate(ctxs)]
    open(p, "w").write("\n".join(L) + "\n")
    return p


def task(name, **fm):
    d = os.path.join(os.environ["COS_DIR"], "tasks")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, f"{name}.md")
    open(p, "w").write("---\nname: %s\n%s---\nbody\n" % (name, "".join(f"{k}: {v}\n" for k, v in fm.items())))
    return p


def child_env(**kw):
    e = dict(os.environ)
    e.update(kw)
    return e


def guard(path, name):
    env = child_env(COS_CONTEXT_MARK_DIR=os.path.join(TMP, "marks-" + name), COS_WORKER=name)
    r = subprocess.run([sys.executable, os.path.join(HERE, "..", "hooks", "context-handoff-guard.py")],
                       input=json.dumps({"transcript_path": path, "session_id": name}), capture_output=True,
                       text=True, env=env)
    return json.loads(r.stdout) if r.stdout.strip() else {}


class FrontmatterRead(unittest.TestCase):
    """2026-11-12: handoff_r lay past the 6000-char read window; the guard recomputed handoff_at every turn."""
    def test_fm_sees_keys_deep_in_a_long_frontmatter(self):
        import tempfile
        d = tempfile.mkdtemp()
        p = os.path.join(d, "a-long-lead-1.md")
        filler = "".join(f'note{i}: "' + "x" * 200 + '"\n' for i in range(40))   # ~8 KB of frontmatter lines
        open(p, "w", encoding="utf-8").write('---\nname: a-long-lead-1\nhandoff_at: 420000\n' + filler +
                                             'handoff_r: 178919\n---\nbody\nhandoff_r: 1\n')
        fm = HO._fm(p)
        self.assertEqual(fm.get("handoff_r"), "178919")      # the frontmatter value, not the body line
        self.assertEqual(fm.get("handoff_at"), "420000")


class HandoffPoint(unittest.TestCase):
    def test_roles_and_defaults(self):
        for n, r in [("a-app-lead-21", "lead"), ("a-chief-1109", "chief"), ("a-release-captain-59", "captain"),
                     ("a-user-tester-5", "tester"), ("a-app-build-60", "builder")]:
            self.assertEqual(HO.role_of(n), r)
        self.assertEqual(HO.default_at("a-app-lead-21"), 700_000)
        self.assertEqual(HO.default_at("a-release-captain-77"), 700_000)
        self.assertEqual(HO.role_of("a-q-build-7", {"lanes": "3"}), "multi")
        self.assertEqual(HO.default_at("a-q-build-7", {"lanes": "3"}), 700_000)
        self.assertEqual(HO.role_of("a-q-build-7", {"lanes": "1"}), "builder")
        self.assertEqual(HO.default_at("a-q-build-7", {"lanes": "1"}), 700_000)
        self.assertEqual(HO.handoff_at({}, "a-app-lead-21"), 800_000)        # no stamp: old session keeps the cap
        self.assertEqual(HO.handoff_at({"handoff_at": "300000"}, "a-y-1"), 700_000)   # builder stamp floored to 700k
        # 0.15.184: a `lanes:` line added after spawn lifts a stamped 300k to the multi-lane floor (no re-stamp needed)
        self.assertEqual(HO.handoff_at({"handoff_at": "300000", "lanes": "2"}, "a-app-chat-8"), 700_000)
        self.assertEqual(HO.handoff_at({"handoff_at": "300000", "lanes": "1"}, "a-app-build-8"), 700_000)
        self.assertEqual(HO.handoff_at({"handoff_at": "350000"}, "a-app-lead-9"), 700_000)   # a lead stamp below 700k is floored
        self.assertEqual(HO.handoff_at({"handoff_at": "900000"}, "a-y-1"), 800_000)   # never above the cap

    def test_recompute_moves_with_R(self):
        self.assertGreaterEqual(HO.recompute("captain", 90_000), 700_000)          # floor: never pulled under the point
        self.assertGreaterEqual(HO.recompute("multi", 90_000), 700_000)
        self.assertGreaterEqual(HO.recompute("builder", 90_000), 700_000)
        self.assertEqual(HO.recompute("lead", 131_000), 700_000)   # floored at 700k
        self.assertGreater(HO.recompute("lead", 250_000), 450_000)
        self.assertGreaterEqual(HO.recompute("lead", 90_000), 700_000)

    def test_guard_blocks_at_task_point_not_cap(self):
        task("a-hp-lead-2", handoff_at=750000, handoff_r=120000)
        self.assertEqual(guard(transcript("a-hp-lead-2", [100_000] * 30 + [740_000]), "a-hp-lead-2"), {})
        out = guard(transcript("a-hp-lead-2", [100_000] * 30 + [760_000]), "a-hp-lead-2")
        self.assertEqual(out.get("decision"), "block")
        self.assertIn("750,000", out["reason"])

    def test_guard_unstamped_session_keeps_cap(self):
        task("a-hp-old-1")
        self.assertEqual(guard(transcript("a-hp-old-1", [100_000] * 30 + [500_000]), "a-hp-old-1"), {})

    def test_guard_measures_R_at_call_20_and_recomputes(self):
        tf = task("a-hp-lead-3", handoff_at=350000, handoff_r='""')
        guard(transcript("a-hp-lead-3", [60_000] * 19 + [250_000] + [255_000] * 5), "a-hp-lead-3")
        fm = HO._fm(tf)
        self.assertEqual(fm["handoff_r"], "250000")
        self.assertGreater(int(fm["handoff_at"]), 400_000)
        tf2 = task("a-hp-lead-4", handoff_at=350000, handoff_r='""')
        guard(transcript("a-hp-lead-4", [60_000] * 19 + [135_000] + [140_000] * 5), "a-hp-lead-4")
        fm2 = HO._fm(tf2)
        self.assertEqual((fm2["handoff_r"], fm2["handoff_at"]), ("135000", "350000"))   # within 25 %: kept

    def test_ctx_flags_against_own_point(self):
        task("a-hp-lead-ctx-1", handoff_at=750000)
        task("a-hp-lead-ctx-2")
        transcript("a-hp-lead-ctx-1", [700_000])
        transcript("a-hp-lead-ctx-2", [500_000])
        tsv = os.path.join(TMP, "sessions.tsv")
        open(tsv, "w").write("state\tname\tpid\tage_m\tidle_m\tacct\tcwd\n"
                             "live\ta-hp-lead-ctx-1\t1\t5\t2\ta\t/x\nlive\ta-hp-lead-ctx-2\t2\t5\t3\ta\t/x\n")
        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, "ctx.py"), "--tsv"], capture_output=True, text=True,
                           env=child_env(COS_CTX_SESSIONS_TSV=tsv))
        rows = {l.split("\t")[0]: l.split("\t") for l in r.stdout.strip().split("\n")[1:]}
        self.assertEqual((rows["a-hp-lead-ctx-1"][4], rows["a-hp-lead-ctx-1"][5]), ("WARN", "750000"))
        self.assertEqual((rows["a-hp-lead-ctx-2"][4], rows["a-hp-lead-ctx-2"][5]), ("", "800000"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
