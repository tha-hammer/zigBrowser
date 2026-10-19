"""S6a part 2 follow-up (RoseCat 5967 on edd2c6c): the login helper's missing contracts.

1. Only the CLI's own authorize URL is reported: besides the origin, path and the
   eight parameter names, each parameter appears once and the captured fixed values
   hold (code=true, response_type=code, scope=user:inference,
   code_challenge_method=S256, that redirect_uri). client_id is a UUID, the
   code_challenge is an S256 challenge (43 base64url characters), and the state is
   non-empty.
2. The first code to arrive is used (D7b `code`): a second code sent before the
   CLI's next prompt never reaches it.
3. Exactly one ending frame: `done`, `error` and `cancel` race for one claim, and
   the token goes to fd 4 only when `done` won it. A cancel that wins means fd 4
   stays empty.

Run alone, like the gate does; it registers with the green."""

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
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from test_login import CANARY, FAKE, URL, Login  # noqa: E402
from zb_agent_host import login  # noqa: E402

CLIENT = "00000000-0000-4000-8000-00000000fa6e"
CHALLENGE = "Zb3_challenge-0123456789abcdefghijklmnopqrs"  # 43 base64url characters
GOOD = ("https://claude.com/cai/oauth/authorize?code=true&client_id=" + CLIENT + "&response_type=code"
        "&redirect_uri=https://platform.claude.com/oauth/code/callback&scope=user:inference"
        "&code_challenge=" + CHALLENGE + "&code_challenge_method=S256&state=st4te")


class AuthorizeUrlValues(unittest.TestCase):
    def test_the_captured_shape_passes(self):
        self.assertEqual(len(CHALLENGE), 43)
        self.assertEqual(login.authorize_url(GOOD), GOOD)
        console = GOOD.replace("https://claude.com/cai/oauth/authorize", "https://platform.claude.com/oauth/authorize")
        self.assertEqual(login.authorize_url(console), console)

    def test_altered_fixed_values_are_refused(self):
        for old, new in (("code=true", "code=false"), ("code=true", "code="),
                         ("response_type=code", "response_type=token"),
                         ("scope=user:inference", "scope=user:inference+user:profile"),
                         ("scope=user:inference", "scope=org:create_api_key"),
                         ("scope=user:inference", "scope="),
                         ("code_challenge_method=S256", "code_challenge_method=plain"),
                         ("code_challenge_method=S256", "code_challenge_method=s256"),
                         ("client_id=" + CLIENT, "client_id="),
                         ("client_id=" + CLIENT, "client_id=not-a-uuid"),
                         ("code_challenge=" + CHALLENGE, "code_challenge="),
                         ("code_challenge=" + CHALLENGE, "code_challenge=" + CHALLENGE[:-1]),
                         ("code_challenge=" + CHALLENGE, "code_challenge=" + CHALLENGE[:-1] + "%"),
                         ("state=st4te", "state=")):
            bad = GOOD.replace(old, new)
            with self.subTest(bad=new):
                self.assertNotEqual(bad, GOOD)
                self.assertIsNone(login.authorize_url(bad))

    def test_a_repeated_parameter_is_refused(self):
        for extra in ("&state=other", "&scope=user:inference", "&code=true"):
            with self.subTest(extra=extra):
                self.assertIsNone(login.authorize_url(GOOD + extra))

    def test_the_helper_refuses_an_altered_scope_end_to_end(self):
        home = Path(tempfile.mkdtemp(prefix="zb-login-contract-"))
        self.addCleanup(shutil.rmtree, home, ignore_errors=True)
        cli = home / "scope-cli"
        cli.write_text("#!/bin/sh\nprintf '%s\\n' '" + GOOD.replace("scope=user:inference", "scope=org:create_api_key")
                       + "' 'Paste code here if prompted >'\nsleep 5\n")
        cli.chmod(0o700)
        h = Login(self, home, cli)
        h.send("start")
        frame = h.frame()
        self.assertEqual((frame["type"], frame["code"]), ("error", "cli"))
        h.finish()


class FirstCodeWins(unittest.TestCase):
    def test_a_second_code_before_the_prompt_never_reaches_the_cli(self):
        home = Path(tempfile.mkdtemp(prefix="zb-login-contract-"))
        self.addCleanup(shutil.rmtree, home, ignore_errors=True)
        (home / ".zb-fake-setup-token").mkdir(mode=0o700)
        (home / ".zb-fake-setup-token" / "token").write_text(CANARY + "\n")
        url = URL.format(state="first")
        cli = home / "slow-cli"
        cli.write_text(f"""#!/bin/sh
printf '%s\\n' '{url}'
while [ ! -e "$HOME/go" ]; do sleep 0.05; done
exec "{FAKE}" "$@"
""")
        cli.chmod(0o700)
        h = Login(self, home, cli)
        h.send("start")
        self.assertEqual(h.frame(), {"type": "auth_url", "url": url})
        h.send("code", code="captured#first")
        h.send("code", code="pasted#second")
        time.sleep(0.3)  # both frames are read before the CLI prompts
        (home / "go").touch()
        self.assertEqual(h.frame(), {"type": "need_code"})
        self.assertEqual(h.frame(), {"type": "need_code"})  # the fake refused the foreign state
        time.sleep(0.5)
        log = home / ".zb-fake-setup-token" / "codes.log"
        self.assertEqual(log.read_text().splitlines(), ["captured#first"])


class Out:
    def __init__(self):
        self.frames = []
        self.lock = threading.Lock()

    def emit(self, type_, **fields):
        with self.lock:
            self.frames.append({"type": type_, **fields})


class OneEnding(unittest.TestCase):
    """The ending claim, driven in-process: the token sits in the helper's screen
    buffer, as after the CLI printed it."""

    TOKEN = CANARY.encode()

    def make(self):
        read, write = os.pipe()
        self.addCleanup(os.close, read)
        out = Out()
        run = login.Login("/nonexistent-home", str(FAKE), out, write)
        run.screen = bytearray(b"Your OAuth token (valid for 1 year):\n" + self.TOKEN + b"\n")
        self.addCleanup(lambda: run.token_fd >= 0 and os.close(run.token_fd))
        start = run.screen.index(self.TOKEN)
        return run, out, read, (start, start + len(self.TOKEN))

    @staticmethod
    def drain(fd):
        os.set_blocking(fd, False)
        try:
            return os.read(fd, 4096)
        except BlockingIOError:
            return b""

    def test_cancel_first_means_no_token_and_one_frame(self):
        run, out, read, span = self.make()
        run.end("error", code="cancelled", message="sign-in cancelled")
        run.hand_off(*span)
        self.assertEqual([f["type"] for f in out.frames], ["error"])
        self.assertEqual(self.drain(read), b"")

    def test_done_first_means_one_frame(self):
        run, out, read, span = self.make()
        run.hand_off(*span)
        run.end("error", code="cancelled", message="sign-in cancelled")
        self.assertEqual([f["type"] for f in out.frames], ["done"])
        self.assertEqual(self.drain(read), self.TOKEN)

    def test_racing_threads_give_exactly_one_ending_and_the_token_only_with_done(self):
        for _ in range(300):
            run, out, read, span = self.make()
            gate = threading.Barrier(3)

            def cancel():
                gate.wait()
                run.end("error", code="cancelled", message="sign-in cancelled")

            def done():
                gate.wait()
                run.hand_off(*span)

            def timeout():
                gate.wait()
                run.end("error", code="timeout", message="sign-in timed out")

            threads = [threading.Thread(target=t) for t in (cancel, done, timeout)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(10)
            self.assertEqual(len(out.frames), 1, out.frames)
            token = self.drain(read)
            if out.frames[0]["type"] == "done":
                self.assertEqual(token, self.TOKEN)
            else:
                self.assertEqual(token, b"")


if __name__ == "__main__":
    unittest.main()
