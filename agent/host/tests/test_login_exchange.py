"""S6b1 part B's finding (chat-drawer plan rev 16.18.9; the orchestrator 2026-10-20, RoseCat 6156).

On the user's screen the real `claude setup-token` took the code and the window said
"Signing in..." for minutes. An offline probe of the real CLI (2.1.294, in a network
namespace with only lo) showed why: the helper gave the CLI no HTTPS_PROXY, so it
resolved platform.claude.com itself, failed, printed "OAuth error: ..." and "Press Enter
to retry." and waited; the helper had no pattern for that and waited out its 10 minutes.

- the CLI's environment carries the backend's relay proxy, as the chat helper's does;
- after a typed code, "OAuth error" or "Press Enter to retry" ends the sign-in at once
  with `error exchange`, and none of the CLI's text is in the frame;
- a CLI that, after a typed code, neither prints the token nor asks again within
  EXCHANGE_S (60 s) ends it with `error timeout`; a new prompt stops that clock.

The CLI is tests/e2e/fake_claude_setup_token.py with its `mode` file, or a small script.
Run the module alone, as the gate does."""

import json
import os
import shutil
import tempfile
import threading
import time
import unittest
from pathlib import Path

import test_login as tl

FAKE = tl.FAKE


class Out:
    def __init__(self):
        self.frames = []
        self.cond = threading.Condition()

    def emit(self, type_, **fields):
        with self.cond:
            self.frames.append({"type": type_, **fields})
            self.cond.notify_all()

    def wait_for(self, pred, timeout):
        with self.cond:
            return self.cond.wait_for(lambda: pred(self.frames), timeout)


class ExchangeTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="zb-login-exch-"))
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)
        (self.home / ".claude").mkdir()
        self.fake = self.home / ".zb-fake-setup-token"
        self.fake.mkdir(mode=0o700)
        (self.fake / "token").write_text(tl.CANARY + "\n", encoding="ascii")

    def mode(self, word):
        (self.fake / "mode").write_text(word + "\n", encoding="ascii")

    def script(self, name, body):
        path = self.home / name
        path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        path.chmod(0o700)
        return path

    def start(self, cli=FAKE):
        h = tl.Login(self, self.home, cli)
        h.send("start")
        return h

    def in_process(self, exchange_s):
        """login.Login run in this process with a short exchange clock: (run, out, write end of
        its stdin, the result holder). The caller sends frames on the write end."""
        from zb_agent_host import login
        read, write = os.pipe()
        token_r, token_w = os.pipe()
        self.addCleanup(os.close, token_r)
        stdin = os.fdopen(read, "r")
        self.addCleanup(stdin.close)
        self.addCleanup(lambda: os.close(write) if write_open[0] else None)
        write_open = [True]
        out = Out()
        run = login.Login(str(self.home), str(FAKE), out, token_w, exchange_s=exchange_s)
        result = {}
        t = threading.Thread(target=lambda: result.setdefault("code", run.run(stdin)), daemon=True)
        os.write(write, b'{"v":1,"seq":1,"type":"start"}\n')
        t.start()
        self.addCleanup(lambda: (run.end("error", code="cancelled", message="test over"), t.join(10)))
        return run, out, write, result, t

    # --- the proxy ---------------------------------------------------------------------
    def test_the_cli_gets_the_relay_proxy(self):
        from zb_agent_host import options
        cli = self.script("env-cli", f"""
env > "$HOME/env"
printf '%s\\n' "{tl.URL.format(state='env')}"
sleep 5
""")
        h = self.start(cli)
        self.assertEqual(h.frame()["type"], "auth_url")
        env = dict(line.split("=", 1) for line in (self.home / "env").read_text().splitlines() if "=" in line)
        self.assertTrue(options.RELAY_PROXY.startswith("http://127.0.0.1:"), options.RELAY_PROXY)
        self.assertEqual(env.get("HTTPS_PROXY"), options.RELAY_PROXY)
        self.assertEqual(env.get("HTTP_PROXY"), options.RELAY_PROXY)
        self.assertEqual(env.get("NO_PROXY"), "127.0.0.1,localhost")

    # --- no silent wait ----------------------------------------------------------------
    def test_an_oauth_error_after_the_code_ends_with_exchange_at_once(self):
        self.mode("oauth-error")
        h = self.start()
        state = tl.state_of(h.frame()["url"])
        self.assertEqual(h.frame(), {"type": "need_code"})
        sent = time.monotonic()
        h.send("code", code=f"c0de#{state}")
        frame = h.frame(timeout=5)
        self.assertLess(time.monotonic() - sent, 5)
        self.assertEqual((frame["type"], frame["code"]), ("error", "exchange"), frame)
        for word in ("OAuth", "EAI_AGAIN", "platform.claude.com", "retry"):
            self.assertNotIn(word, frame["message"])  # the CLI's own text never leaves the helper
        code, _err, token = h.finish()
        self.assertEqual((code, token), (1, b""))

    def test_a_bare_press_enter_to_retry_also_ends_with_exchange(self):
        # The renderer draws spaces as cursor moves.
        cli = self.script("retry-cli", f"""
printf '%s\\n' "{tl.URL.format(state='retry')}"
printf 'Paste\\033[1Ccode\\033[1Chere\\033[1Cif\\033[1Cprompted\\033[1C> '
read line
printf 'Press\\033[1CEnter\\033[1Cto\\033[1Cretry.\\n'
sleep 30
""")
        h = self.start(cli)
        h.frame()
        self.assertEqual(h.frame(), {"type": "need_code"})
        h.send("code", code="c0de#retry")
        frame = h.frame(timeout=5)
        self.assertEqual((frame["type"], frame["code"]), ("error", "exchange"), frame)

    def test_the_exchange_clock_is_sixty_seconds(self):
        from zb_agent_host import login
        self.assertEqual(login.EXCHANGE_S, 60)
        self.assertEqual(login.TIMEOUT_S, 600)

    def test_silence_after_a_code_ends_with_timeout_on_the_exchange_clock(self):
        self.mode("silent")
        run, out, write, result, t = self.in_process(exchange_s=1)
        self.assertTrue(out.wait_for(lambda f: {"type": "need_code"} in f, 15), out.frames)
        state = tl.state_of(next(f["url"] for f in out.frames if f["type"] == "auth_url"))
        os.write(write, json.dumps({"v": 1, "seq": 2, "type": "code", "code": f"c0de#{state}"}).encode() + b"\n")
        sent = time.monotonic()
        self.assertTrue(out.wait_for(lambda f: f[-1]["type"] in ("error", "done"), 6), out.frames)
        elapsed = time.monotonic() - sent
        self.assertEqual((out.frames[-1]["type"], out.frames[-1]["code"]), ("error", "timeout"), out.frames)
        self.assertTrue(0.8 <= elapsed < 4, elapsed)
        t.join(10)
        self.assertEqual(result.get("code"), 1)

    def test_a_refused_code_stops_the_exchange_clock(self):
        run, out, write, result, t = self.in_process(exchange_s=1)
        self.assertTrue(out.wait_for(lambda f: {"type": "need_code"} in f, 15), out.frames)
        state = tl.state_of(next(f["url"] for f in out.frames if f["type"] == "auth_url"))
        os.write(write, json.dumps({"v": 1, "seq": 2, "type": "code", "code": "c0de#ANOTHERSIGNIN"}).encode() + b"\n")
        self.assertTrue(out.wait_for(lambda f: f.count({"type": "need_code"}) == 2, 10), out.frames)
        time.sleep(2.5)  # past the 1 s clock: the CLI asked again, so the user has their 10 minutes
        self.assertEqual([f["type"] for f in out.frames], ["auth_url", "need_code", "need_code"], out.frames)
        os.write(write, json.dumps({"v": 1, "seq": 3, "type": "code", "code": f"c0de#{state}"}).encode() + b"\n")
        self.assertTrue(out.wait_for(lambda f: f[-1]["type"] in ("error", "done"), 10), out.frames)
        self.assertEqual(out.frames[-1], {"type": "done"})


if __name__ == "__main__":
    unittest.main()
