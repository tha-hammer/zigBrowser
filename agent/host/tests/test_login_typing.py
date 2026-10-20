"""Typing the code so its Enter can never join a paste (chat-drawer plan rev 16.20.29; RoseCat
6499 on b4d5b86).

0.15 s of quiet is no proof that the CLI read the whole code: a CLI that stalls 0.35 s after
each 40-byte read got the Enter with a 24-byte remainder ([(40,0),(40,0),(40,0),(24,1)]). And
the real CLI's echo is not one '*' per typed character as the helper's screen sees it (2.1.294,
probed offline: a cursor move, then the line redrawn, six characters fewer stars than were
typed), so the Enter cannot wait for a full count either. So the helper types the code in
pieces of at most CHUNK bytes, and writes each next piece, and at last the Enter, only once
the masked echo accounts for all but at most CHUNK of the typed bytes (a '*' only for a
character the CLI read). A read holding the Enter then holds at most CHUNK other bytes, far
below the paste rule's 64, however the CLI stalls. A step the echo does not account for
within STEP_S fails closed: `error cli`, and no Enter. Run the module alone, as the gate does."""

import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_login import CANARY, LoginTest, state_of  # noqa: E402
from test_login_paste import REAL_LENGTH  # noqa: E402
from zb_agent_host import login  # noqa: E402

CHUNK = getattr(login, "CHUNK", 16)  # the green's values; before it, these
STEP_S = getattr(login, "STEP_S", 5.0)  # make the red fail on behaviour, not a name


class Typing(unittest.TestCase):
    setUp, codes, start = LoginTest.setUp, LoginTest.codes, LoginTest.start

    def fake_file(self, name, text):
        (self.home / ".zb-fake-setup-token" / name).write_text(text, encoding="ascii")

    def reads(self):
        log = self.home / ".zb-fake-setup-token" / "reads.log"
        return [tuple(int(v) for v in line.split()) for line in log.read_text().splitlines()] if log.exists() else []

    def test_a_cli_that_stalls_between_reads_still_gets_an_enter_it_submits(self):
        """RoseCat 6499's reproducer: at most 40 bytes a read, 0.35 s after each."""
        self.fake_file("read-max", "40\n")
        self.fake_file("read-delay", "0.35\n")
        h = self.start()
        state = state_of(h.frame()["url"])
        self.assertEqual(h.frame(), {"type": "need_code"})
        code = f"{REAL_LENGTH}#{state}"
        h.send("code", code=code)
        self.assertEqual(h.frame(timeout=30), {"type": "done"})
        rc, _err, token = h.finish()
        self.assertEqual((rc, token), (0, CANARY.encode()))
        self.assertEqual(self.codes(), [code])
        reads = self.reads()
        with_enter = [r for r in reads if r[1]]
        self.assertEqual(len(with_enter), 1, reads)
        self.assertLessEqual(with_enter[0][0], CHUNK,
                             f"the Enter's read holds at most CHUNK ({CHUNK}) code bytes ({reads})")
        self.assertEqual(sum(n for n, _ in reads), len(code), reads)

    def test_a_cli_whose_echo_never_comes_fails_closed_without_an_enter(self):
        self.fake_file("no-echo", "")
        h = self.start()
        h.frame()
        self.assertEqual(h.frame(), {"type": "need_code"})
        started = time.monotonic()
        h.send("code", code=f"{REAL_LENGTH}#{state_of('https://x/?state=s')}")
        frame = h.frame(timeout=STEP_S + 10)
        self.assertEqual((frame["type"], frame.get("code")), ("error", "cli"), frame)
        self.assertGreaterEqual(time.monotonic() - started, STEP_S - 0.5)
        h.finish()
        self.assertEqual([r for r in self.reads() if r[1]], [], f"no Enter reached the CLI ({self.reads()})")
        self.assertLessEqual(sum(n for n, _ in self.reads()), 2 * CHUNK,
                             "typing stopped once the unechoed bytes passed CHUNK")


del LoginTest

if __name__ == "__main__":
    unittest.main()
