"""The typed code's own Enter (chat-drawer plan rev 16.20.28; RoseCat 6493 on 7736972).

1. No Enter after the ending: the delayed Enter and every ending (cancel, the app's EOF, a
   timeout, an error, done) are one linearization. Once an ending is claimed, no Enter
   reaches the CLI: it could submit a code the user has already cancelled.
2. The Enter comes after all of the code: a CLI may take a code in several reads (a pty write
   is no read boundary), so the Enter waits until the CLI's masked echo has appeared AND its
   output has been quiet (rev 16.20.29: the Enter goes once the echo accounts for all but CHUNK
   typed bytes, so its read holds at most CHUNK code bytes, never a paste).
Run the module alone, as the gate does."""

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
from test_login_paste import REAL_LENGTH  # noqa: E402
from zb_agent_host.login import CHUNK  # noqa: E402


def helper(home):
    from zb_agent_host import login

    class Out:
        def __init__(self):
            self.frames = []

        def emit(self, type_, **fields):
            self.frames.append({"type": type_, **fields})

    token_r, token_w = os.pipe()
    os.close(token_r)
    return login.Login(str(home), str(FAKE), Out(), token_w)


class NoEnterAfterTheEnding(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="zb-login-unit-"))
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)

    def pending(self):
        """A helper whose CLI end is a pipe we read, with an Enter pending."""
        run = helper(self.home)
        r, w = os.pipe()
        os.set_blocking(r, False)
        self.addCleanup(os.close, r)
        self.addCleanup(os.close, w)
        run.master = w
        run.enter_by = time.monotonic() + 30
        self.addCleanup(lambda: run.token_fd >= 0 and os.close(run.token_fd))  # RoseCat 6499 SHOULD
        return run, r

    @staticmethod
    def written(r):
        try:
            return os.read(r, 4096)
        except BlockingIOError:
            return b""

    def test_an_ending_first_then_the_enter_writes_nothing(self):
        for ending in ("cancelled", "timeout", "cli", "exchange"):
            run, r = self.pending()
            run.end("error", code=ending, message="x")
            with run.lock:
                run.enter()
            self.assertEqual(self.written(r), b"", ending)
            self.assertIsNone(run.enter_by, f"{ending}: the pending Enter is cleared")

    def test_a_cancel_during_the_enters_write_is_reported_after_it(self):
        """The Enter's write is held open for 0.3 s; a cancel comes 0.1 s into it. With one
        linearization the cancel waits, and the Enter is already there when the ending is
        reported; checked, then written outside that order, the Enter lands after it."""
        from zb_agent_host import login
        run, r = self.pending()
        real_write = login.os.write

        def slow_write(fd, data):
            if fd == run.master and data == b"\r":
                time.sleep(0.3)
            return real_write(fd, data)

        seen_at_end = []
        emit = run.out.emit

        def recording(type_, **fields):
            seen_at_end.append(self.written(r))
            emit(type_, **fields)

        run.out.emit = recording
        login.os.write = slow_write
        self.addCleanup(setattr, login.os, "write", real_write)

        def enter():
            with run.lock:
                run.enter()

        writer = threading.Thread(target=enter)
        writer.start()
        time.sleep(0.1)
        run.end("error", code="cancelled", message="sign-in cancelled")
        writer.join(5)
        login.os.write = real_write
        late = self.written(r)
        self.assertEqual((seen_at_end, late), ([b"\r"], b""),
                         "the Enter must be written before the ending is reported, never after it")

    def test_cancel_racing_the_enter_never_writes_after_the_ending(self):
        """The same, unforced, 300 times."""
        late = 0
        for _ in range(300):
            run, r = self.pending()
            gate = threading.Barrier(2)

            def cancel():
                gate.wait()
                run.end("error", code="cancelled", message="sign-in cancelled")

            def enter():
                gate.wait()
                with run.lock:
                    run.enter()

            emit = run.out.emit
            reported = []
            run.out.emit = lambda type_, **fields: (reported.append(self.written(r)), emit(type_, **fields))
            threads = [threading.Thread(target=cancel), threading.Thread(target=enter)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(5)
            if self.written(r):
                late += 1
        self.assertEqual(late, 0, f"{late} of 300 runs wrote the Enter after the ending was reported")


class TheEnterAfterAllOfTheCode(unittest.TestCase):
    setUp, codes, start = LoginTest.setUp, LoginTest.codes, LoginTest.start

    def reads(self):
        log = self.home / ".zb-fake-setup-token" / "reads.log"
        return [tuple(int(v) for v in line.split()) for line in log.read_text().splitlines()] if log.exists() else []

    def test_a_cli_that_reads_the_code_in_pieces_gets_the_enter_alone(self):
        (self.home / ".zb-fake-setup-token" / "read-max").write_text("40\n", encoding="ascii")
        h = self.start()
        state = state_of(h.frame()["url"])
        self.assertEqual(h.frame(), {"type": "need_code"})
        code = f"{REAL_LENGTH}#{state}"
        h.send("code", code=code)
        self.assertEqual(h.frame(timeout=15), {"type": "done"})
        rc, _err, token = h.finish()
        self.assertEqual((rc, token), (0, CANARY.encode()))
        self.assertEqual(self.codes(), [code])
        reads = self.reads()
        self.assertGreater(len(reads), 2, f"the fake took the code in pieces ({reads})")
        self.assertEqual(reads[-1][1], 1, f"the last read holds the Enter ({reads})")
        self.assertLessEqual(reads[-1][0], CHUNK, f"with at most CHUNK code bytes (rev 16.20.29; {reads})")
        self.assertEqual(sum(n for n, _ in reads), len(code), reads)

    def test_the_app_going_away_with_an_enter_pending_sends_no_enter(self):
        """A CLI that does not echo, so the Enter waits (rev 16.20.29: for the echo, up to
        STEP_S); the app's EOF (its cancel, or the window closed) comes first: the CLI never
        gets an Enter."""
        (self.home / ".zb-fake-setup-token" / "no-echo").write_text("", encoding="ascii")
        h = self.start()
        h.frame()
        self.assertEqual(h.frame(), {"type": "need_code"})
        h.send("code", code=f"{REAL_LENGTH}#s")
        time.sleep(0.2)
        h.proc.stdin.close()
        self.assertEqual(h.frame(timeout=10)["code"], "cancelled")
        h.proc.wait(10)
        time.sleep(1.5)
        self.assertEqual([n for n in self.reads() if n[1]], [], f"no read with an Enter ({self.reads()})")


del LoginTest

if __name__ == "__main__":
    unittest.main()
