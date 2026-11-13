"""lastturn.last_human_turn must not count machine-typed user turns as the user typing.

Run: python3 -m unittest -v test_lastturn.py  (from this directory)
"""
import calendar, json, os, tempfile, time, unittest

import lastturn as LT


def ts(sec):  # ISO-Z stamp for epoch sec (UTC)
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(sec))


def line(text, sec, origin="human"):
    return json.dumps({"type": "user", "isMeta": False, "origin": {"kind": origin}, "parentUuid": "p",
                       "timestamp": ts(sec), "message": {"content": text}})


SPAWN = ("CAVEMAN STYLE. You are a worker session spawned by the chief of staff. Read your charter at "
         "~/cos/charters/x.md — then do it.")
CONT = "MANDATORY FIRST STEP: you continue worker w-old-1. Read its session file (Resume Here first)."
T0 = calendar.timegm(time.strptime("2026-11-08 10:00:00", "%Y-%m-%d %H:%M:%S"))


class HumanTurn(unittest.TestCase):
    def transcript(self, *lines):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "s.jsonl")
        with open(p, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        return p

    def test_fresh_spawn_has_no_human_turn(self):
        self.assertEqual(LT.last_human_turn(self.transcript(line(SPAWN, T0))), -1)

    def test_continue_first_step_has_no_human_turn(self):
        self.assertEqual(LT.last_human_turn(self.transcript(line(CONT, T0))), -1)

    def test_real_message_after_spawn_counts(self):
        p = self.transcript(line(SPAWN, T0), line("please check the card", T0 + 600))
        self.assertEqual(LT.last_human_turn(p), T0 + 600)

    def test_ck_ping_ignored(self):
        self.assertEqual(LT.last_human_turn(self.transcript(line("⟦CK⟧ check-in", T0))), -1)

    def test_cross_session_message_ignored(self):
        msg = '<cross-session-message from="x">Ping</cross-session-message>'
        self.assertEqual(LT.last_human_turn(self.transcript(line(msg, T0))), -1)

    def test_slash_command_ignored(self):
        cmd = "<command-name>/color</command-name>\n<command-message>color</command-message>"
        self.assertEqual(LT.last_human_turn(self.transcript(line(cmd, T0))), -1)

    def test_wake_guard_park_message_ignored(self):
        # the wake-guard tick types its park message into the pane; it must not count as the user typing
        # (else stop.sh refuses with exit 8 every minute)
        txt = "wake-guard: your prompt cache goes cold in about 10 min. Do ONE cheap turn now"
        self.assertEqual(LT.last_human_turn(self.transcript(line(txt, T0))), -1)
        self.assertEqual(LT.last_human_turn(self.transcript(line("real question", T0), line(txt, T0 + 60))), T0)

    def test_injected_notices_ignored(self):
        for txt in ("<task-notification>cos-msg 12</task-notification>", "<system-reminder>x</system-reminder>"):
            self.assertEqual(LT.last_human_turn(self.transcript(line(txt, T0))), -1)

    def test_non_human_origin_ignored(self):
        self.assertEqual(LT.last_human_turn(self.transcript(line("hello", T0, origin="peer"))), -1)


def asst(sec, err=False):
    d = {"type": "assistant", "timestamp": ts(sec), "message": {"model": "<synthetic>" if err else "claude-opus-5-5", "content": []}}
    if err: d["isApiErrorMessage"] = True
    return json.dumps(d)


class OkTurn(unittest.TestCase):
    def transcript(self, *lines):
        f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        f.write("\n".join(lines) + "\n"); f.close(); self.addCleanup(os.unlink, f.name); return f.name

    def test_api_error_is_not_a_cache_turn(self):
        # 2026-11-11: real reply 18:50, then cron prompts + `API Error` entries until 20:33
        p = self.transcript(asst(T0), line("cron sweep", T0 + 900, origin="peer"), asst(T0 + 1000, err=True))
        self.assertEqual(LT.last_ok_turn(p), T0)
        self.assertEqual(LT.last_turn(p)[0], T0 + 900)       # error entry skipped, the cron prompt still counts
        self.assertEqual(LT.last_activity(p), T0 + 1000)     # but it is activity (busy window)

    def test_no_real_reply(self):
        self.assertEqual(LT.last_ok_turn(self.transcript(line("hi", T0))), -1)


if __name__ == "__main__":
    unittest.main()
