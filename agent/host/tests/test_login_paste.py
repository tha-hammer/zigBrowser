"""Part B's second finding (chat-drawer plan rev 16.20.27; 2026-10-20): a real-length code.

The real CLI 2.1.294 reads its terminal raw, and one read that holds the Enter and more than
about 64 other bytes is a paste: the text goes into its input (masked) and the Enter does
not submit it. The helper typed `<code>#<state>` and its Enter in one write, so with a real
code (its state alone is 43 characters) the CLI never exchanged it, and the sign-in ended
`timeout` 60 s later with no CONNECT to platform.claude.com (probed offline against the real
CLI, through the real helper, relay and login netd). tests/e2e/fake_claude_setup_token.py
now has that paste rule and logs each read's size (reads.log). The helper must type the
code, and send the Enter as its own write once the CLI has taken the code in. Run the
module alone, as the gate does."""

import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_login import CANARY, FAKE, LoginTest, state_of  # noqa: E402
from zb_agent_host import login  # noqa: E402

REAL_LENGTH = ("zbRealLengthCode-" * 8)[:100]  # a 100-character code


class PasteTest(unittest.TestCase):
    setUp, codes, start = LoginTest.setUp, LoginTest.codes, LoginTest.start

    def reads(self):
        log = self.home / ".zb-fake-setup-token" / "reads.log"
        return [tuple(int(v) for v in line.split()) for line in log.read_text().splitlines()] if log.exists() else []

    def sign_in(self, code_part):
        h = self.start()
        state = state_of(h.frame()["url"])
        self.assertEqual(h.frame(), {"type": "need_code"})
        code = f"{code_part}#{state}"
        h.send("code", code=code)
        self.assertEqual(h.frame(timeout=15), {"type": "done"})
        rc, _err, token = h.finish()
        self.assertEqual((rc, token), (0, CANARY.encode()))
        self.assertEqual(self.codes(), [code])
        return code

    def test_a_real_length_code_is_exchanged(self):
        self.sign_in(REAL_LENGTH)

    def test_the_enter_shares_a_read_with_at_most_chunk_code_bytes(self):
        code = self.sign_in(REAL_LENGTH)
        reads = self.reads()
        # Rev 16.20.29: the Enter's read holds at most CHUNK code bytes (BlackRobin 6535: never
        # "alone" under that pacing, which keeps the paste rule out of reach, not the Enter apart).
        self.assertEqual(reads[-1][1], 1, f"the last read holds the Enter ({reads})")
        self.assertLessEqual(reads[-1][0], login.CHUNK, f"with at most CHUNK code bytes ({reads})")
        self.assertEqual(sum(n for n, _ in reads), len(code), f"the code arrived, without its Enter ({reads})")
        self.assertTrue(all(ends == 0 for _, ends in reads[:-1]), f"no Enter came with the code ({reads})")

    def test_a_short_code_still_works(self):
        self.sign_in("c0de")

    def test_a_code_too_short_to_echo_still_gets_its_enter(self):
        """No run of 8 stars: the Enter still goes, alone, once the echo grew (rev 16.20.29), and
        the CLI answers it (here: not this sign-in's code, so it asks again)."""
        h = self.start()
        h.frame()
        self.assertEqual(h.frame(), {"type": "need_code"})
        h.send("code", code="a#b")
        self.assertEqual(h.frame(timeout=10), {"type": "need_code"})
        self.assertEqual(self.codes(), ["a#b"])
        self.assertEqual(self.reads()[-1][1], 1, self.reads())
        self.assertLessEqual(self.reads()[-1][0], login.CHUNK, self.reads())


class EchoTest(unittest.TestCase):
    """In process, with the step bound pushed out of reach (rev 16.20.29: STEP_S): the CLI's
    masked echo alone paces the pieces and the Enter, and a real-length code still finishes at
    once."""

    def test_the_enter_follows_the_echo_not_the_fallback_clock(self):
        from zb_agent_host import login
        self.addCleanup(setattr, login, "STEP_S", login.STEP_S)
        login.STEP_S = 30.0
        home = Path(tempfile.mkdtemp(prefix="zb-login-unit-"))
        self.addCleanup(shutil.rmtree, home, ignore_errors=True)
        (home / ".claude").mkdir()
        (home / ".zb-fake-setup-token").mkdir(mode=0o700)
        (home / ".zb-fake-setup-token" / "token").write_text(CANARY + "\n", encoding="ascii")
        out = []

        class Out:
            def emit(self, type_, **fields):
                out.append({"type": type_, **fields})

        read, write = os.pipe()
        token_r, token_w = os.pipe()
        self.addCleanup(os.close, token_r)
        stdin = os.fdopen(read, "r")
        self.addCleanup(stdin.close)
        run = login.Login(str(home), str(FAKE), Out(), token_w, timeout_s=60)
        worker = threading.Thread(target=run.run, args=(stdin,), daemon=True)
        os.write(write, b'{"v":1,"seq":1,"type":"start"}\n')
        worker.start()
        self.addCleanup(worker.join, 15)
        self.addCleanup(os.close, write)

        def wait(pred, secs):
            deadline = time.monotonic() + secs
            while not pred() and time.monotonic() < deadline:
                time.sleep(0.02)
            return pred()

        self.assertTrue(wait(lambda: any(f["type"] == "need_code" for f in out), 15), out)
        state = state_of(next(f["url"] for f in out if f["type"] == "auth_url"))
        frame = {"v": 1, "seq": 2, "type": "code", "code": f"{REAL_LENGTH}#{state}"}
        started = time.monotonic()
        os.write(write, (json.dumps(frame) + "\n").encode())
        self.assertTrue(wait(lambda: out[-1]["type"] in ("done", "error"), 10), out)
        self.assertEqual(out[-1], {"type": "done"})
        self.assertLess(time.monotonic() - started, 5, "the steps waited for the bound, not the echo")


del LoginTest  # PasteTest borrows its home and helpers; its own cases run in test_login

if __name__ == "__main__":
    unittest.main()
