"""S6a (chat-drawer plan D7b, D11 login capture; rev 16.18): `python -m zb_agent_host login`.

The one-shot sign-in helper runs `claude setup-token` on a pty and reports the
authorize URL; the app sends `<code>#<state>` (captured or pasted); the helper
types it at the CLI's prompt; the token goes only to fd 4. The CLI here is
tests/e2e/fake_claude_setup_token.py, which replays the real CLI's capture
(fake_claude_setup_token_test.py checks that), or a small script for one edge.
Run the module alone, as the gate does."""

import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

HOST_DIR = Path(__file__).resolve().parents[1]
REPO = HOST_DIR.parents[1]
FAKE = REPO / "tests" / "e2e" / "fake_claude_setup_token.py"
sys.path.insert(0, str(HOST_DIR))

CANARY = "sk-ant-oat01-ZBCANARY-login-unit-0123456789"
REDIRECT = "https://platform.claude.com/oauth/code/callback"
URL = ("https://claude.com/cai/oauth/authorize?code=true&client_id=00000000-0000-4000-8000-00000000fa6e"
       "&response_type=code&redirect_uri=" + REDIRECT + "&scope=user:inference"
       "&code_challenge=Zb3_challenge-0123456789abcdefghijklmnopqrs"  # an S256 challenge's shape (RoseCat 5967)
       "&code_challenge_method=S256&state={state}")
INVALID = "Invalid code. Please make sure the full code was copied."


def state_of(url):
    return dict(parse_qsl(urlsplit(url).query))["state"]


class Login:
    """The helper as the app starts it: fixed argv, NDJSON on stdin and stdout, fd 4 a pipe."""

    def __init__(self, tc, home, cli, argv=None):
        self.tc = tc
        read, write = os.pipe()
        env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONPATH": str(HOST_DIR),
               "PYTHONDONTWRITEBYTECODE": "1", "HOME": str(home)}
        move = "" if write == 4 else f"exec 4>&{write} {write}>&-; "
        args = argv if argv is not None else ["--home", str(home), "--e2e-claude-cli", str(cli)]
        self.proc = subprocess.Popen(["/bin/sh", "-c", move + 'exec "$0" "$@"', sys.executable, "-m", "zb_agent_host",
                                      "login", *args],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=env, pass_fds=(write,), start_new_session=True)
        os.close(write)
        self.token_read = read
        self.token = bytearray()
        self.seq = 0
        self.lines = queue.Queue()
        self.raw_out = bytearray()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.token_reader = threading.Thread(target=self._read_token, daemon=True)
        self.token_reader.start()
        tc.addCleanup(self.kill)

    def _read(self):
        for line in self.proc.stdout:
            self.raw_out += line
            self.lines.put(line)
        self.lines.put(None)

    def _read_token(self):
        while True:
            chunk = os.read(self.token_read, 4096)
            if not chunk:
                break
            self.token += chunk
        os.close(self.token_read)

    def send(self, type_, **fields):
        self.seq += 1
        self.send_raw(json.dumps({"v": 1, "seq": self.seq, "type": type_, **fields}))

    def send_raw(self, text):
        self.proc.stdin.write(text.encode() + b"\n")
        self.proc.stdin.flush()

    def frame(self, timeout=20):
        try:
            line = self.lines.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError("no frame") from None
        if line is None:
            self.lines.put(None)
            raise AssertionError("helper exited before the frame")
        frame = json.loads(line)
        self.tc.assertEqual((frame.pop("v"), type(frame.pop("seq"))), (1, int))
        return frame

    def finish(self, timeout=20):
        """Exit status, stderr and the token bytes, after the helper ends."""
        code = self.proc.wait(timeout=timeout)
        self.reader.join(timeout)
        self.token_reader.join(timeout)
        err = self.proc.stderr.read()
        return code, err, bytes(self.token)

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        for f in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            try:
                f.close()
            except OSError:
                pass
        self.reader.join(5)
        self.token_reader.join(5)


class LoginTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="zb-login-unit-"))
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)
        (self.home / ".claude").mkdir()
        fake = self.home / ".zb-fake-setup-token"
        fake.mkdir(mode=0o700)
        (fake / "token").write_text(CANARY + "\n", encoding="ascii")

    def codes(self):
        log = self.home / ".zb-fake-setup-token" / "codes.log"
        return log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    def script(self, name, body):
        """A stand-in CLI for one edge: a shell script in the home."""
        path = self.home / name
        path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        path.chmod(0o700)
        return path

    def start(self, cli=FAKE):
        h = Login(self, self.home, cli)
        h.send("start")
        return h

    def test_sign_in_gives_the_token_on_fd_4_only(self):
        h = self.start()
        url = h.frame()
        self.assertEqual(url["type"], "auth_url")
        state = state_of(url["url"])
        self.assertEqual(h.frame(), {"type": "need_code"})
        h.send("code", code=f"fakecode-0123#{state}")
        self.assertEqual(h.frame(), {"type": "done"})
        code, err, token = h.finish()
        self.assertEqual(code, 0)
        self.assertEqual(token, CANARY.encode())
        self.assertEqual(self.codes(), [f"fakecode-0123#{state}"])
        self.assertNotIn(b"sk-ant", bytes(h.raw_out))
        self.assertNotIn(b"sk-ant", err)
        self.assertNotIn(b"ZBCANARY", bytes(h.raw_out) + err)

    def test_the_authorize_url_is_the_captured_one(self):
        h = self.start()
        url = urlsplit(h.frame()["url"])
        self.assertEqual(f"{url.scheme}://{url.netloc}{url.path}", "https://claude.com/cai/oauth/authorize")
        names = [name for name, _ in parse_qsl(url.query)]
        self.assertEqual(names, ["code", "client_id", "response_type", "redirect_uri", "scope", "code_challenge",
                                 "code_challenge_method", "state"])

    def test_a_refused_code_asks_again(self):
        h = self.start()
        state = state_of(h.frame()["url"])
        self.assertEqual(h.frame(), {"type": "need_code"})
        h.send("code", code="fakecode#" + "A" * 43)  # another sign-in's state: the CLI refuses it
        self.assertEqual(h.frame(), {"type": "need_code"})
        h.send("code", code=f"fakecode#{state}")
        self.assertEqual(h.frame(), {"type": "done"})
        self.assertEqual(h.finish()[2], CANARY.encode())
        self.assertEqual(self.codes(), ["fakecode#" + "A" * 43, f"fakecode#{state}"])

    def test_a_code_sent_before_the_prompt_waits_for_it(self):
        url = URL.format(state="early")
        cli = self.script("slow-cli", f"""
printf '%s\\n' '{url}'
sleep 1
/usr/bin/python3 -IS -c 'import termios; termios.tcflush(0, termios.TCIFLUSH)'
exec "{FAKE}" "$@"
""")
        # The slow CLI prints its own URL, then the fake's; the helper reports the first.
        # Before its prompt the real CLI's renderer reads keys itself ("c to copy"), so
        # anything typed early is lost: here, flushed.
        h = self.start(cli)
        self.assertEqual(h.frame(), {"type": "auth_url", "url": url})
        h.send("code", code="early#early")
        time.sleep(0.3)
        self.assertEqual(self.codes(), [])  # nothing typed before the prompt
        self.assertEqual(h.frame(), {"type": "need_code"})
        self.assertEqual(h.frame(), {"type": "need_code"})  # the fake refused the foreign state
        self.assertEqual(self.codes(), ["early#early"])

    def test_cancel_ends_the_cli(self):
        cli = self.script("pid-cli", f'echo $$ > "$HOME/cli.pid"\nexec "{FAKE}" "$@"\n')
        h = self.start(cli)
        h.frame()
        h.frame()
        pid = int((self.home / "cli.pid").read_text())
        h.send("cancel")
        self.assertEqual(h.frame()["type"], "error")
        code, _, token = h.finish()
        self.assertEqual(token, b"")
        self.assertEqual(code, 1)
        self.assertFalse(Path(f"/proc/{pid}").exists())

    def test_cancel_is_an_error_frame_named_cancelled(self):
        h = self.start()
        self.assertEqual(h.frame()["type"], "auth_url")
        self.assertEqual(h.frame(), {"type": "need_code"})
        h.send("cancel")
        frame = h.frame()
        self.assertEqual((frame["type"], frame["code"]), ("error", "cancelled"))
        self.assertEqual(h.finish()[2], b"")

    def test_stdin_closed_is_cancelled(self):
        h = self.start()
        self.assertEqual(h.frame()["type"], "auth_url")
        self.assertEqual(h.frame(), {"type": "need_code"})
        h.proc.stdin.close()
        frame = h.frame()
        self.assertEqual((frame["type"], frame["code"]), ("error", "cancelled"))

    def test_a_cli_that_ends_without_a_token_is_an_error(self):
        url = URL.format(state="s")
        h = self.start(self.script("dead-cli", f"printf '%s\\n' '{url}'\nexit 3\n"))
        self.assertEqual(h.frame()["type"], "auth_url")
        frame = h.frame()
        self.assertEqual((frame["type"], frame["code"]), ("error", "cli"))
        self.assertEqual(h.finish()[2], b"")

    def test_a_success_line_without_a_setup_token_is_shape(self):
        url = URL.format(state="s")
        h = self.start(self.script("bad-token-cli", f"""printf '%s\\n' '{url}'
printf '%s\\n' 'Paste code here if prompted >'
read line
printf '%s\\n' '✓ Long-lived authentication token created successfully!' 'Your OAuth token (valid for 1 year):' 'sk-ant-api03-not-a-setup-token-0123456789'
"""))
        h.frame()
        h.frame()
        h.send("code", code="c#s")
        frame = h.frame()
        self.assertEqual((frame["type"], frame["code"]), ("error", "shape"))
        code, err, token = h.finish()
        self.assertEqual(token, b"")
        self.assertNotIn(b"sk-ant", bytes(h.raw_out) + err)

    def test_an_unexpected_authorize_url_is_refused(self):
        for bad in (URL.format(state="s") + "&extra=1",
                    URL.format(state="s").replace("https://claude.com/", "https://claude.com.evil.test/"),
                    URL.format(state="s").replace("redirect_uri=https://platform.claude.com/", "redirect_uri=https://evil.test/"),
                    URL.format(state="s").replace("https://", "http://"),
                    URL.format(state="")):
            with self.subTest(bad=bad):
                cli = self.script("odd-url-cli", f"printf '%s\\n' '{bad}' 'Paste code here if prompted >'\nsleep 5\n")
                h = self.start(cli)
                frame = h.frame()
                self.assertEqual((frame["type"], frame["code"]), ("error", "cli"))
                h.finish()

    def test_bad_code_frames_never_reach_the_cli(self):
        for bad in ("a b#s", "a#s\n", "a\r#s", "a\x03#s", "nohash", "#s", "a#", "a#b#c", "c" * 600 + "#s", 7):
            with self.subTest(bad=bad):
                h = self.start()
                h.frame()
                h.frame()
                h.send("code", code=bad)
                frame = h.frame()
                self.assertEqual((frame["type"], frame["code"]), ("error", "protocol"))
                h.finish()
                self.assertEqual(self.codes(), [])

    def test_the_first_frame_must_be_start(self):
        h = Login(self, self.home, FAKE)
        h.send("code", code="a#b")
        frame = h.frame()
        self.assertEqual((frame["type"], frame["code"]), ("error", "protocol"))
        self.assertEqual(h.finish()[0], 2)

    def test_no_fd_4_refuses(self):
        proc = subprocess.run([sys.executable, "-m", "zb_agent_host", "login", "--home", str(self.home),
                               "--e2e-claude-cli", str(FAKE)], cwd=str(HOST_DIR), capture_output=True,
                              stdin=subprocess.DEVNULL, timeout=20,
                              env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(HOST_DIR), "PYTHONDONTWRITEBYTECODE": "1"})
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, b"")
        self.assertIn(b"no fd 4", proc.stderr)

    def test_the_cli_gets_a_wide_pty_and_a_fixed_environment(self):
        # The CLI puts what it sees into its URL's state (unreserved characters only).
        cli = self.script("env-cli", f"""
cols=$(stty size | cut -d' ' -f2)
names=$(env | cut -d= -f1 | sort | tr '\\n' '.')
case "$HOME|$CLAUDE_CONFIG_DIR|$BROWSER" in
  "{self.home}|{self.home}/.claude|/bin/true") ok=ok ;;
  *) ok=bad ;;
esac
printf '%s\\n' "{URL.format(state='cols$cols.$ok.$names')}"
sleep 5
""")
        h = self.start(cli)
        state = state_of(h.frame()["url"])
        self.assertTrue(state.startswith("cols4096.ok."), state)
        names = set(state.split(".")[2:]) - {""}
        self.assertTrue({"HOME", "CLAUDE_CONFIG_DIR", "BROWSER", "PATH"} <= names, names)
        self.assertFalse(names & {"DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "SSH_AUTH_SOCK",
                                  "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"}, names)

    def test_escapes_and_an_osc8_link_are_dropped(self):
        # The renderer draws spaces as cursor moves (the capture lost them) and may wrap
        # the URL in an OSC 8 link.
        url = URL.format(state="osc8")
        cli = self.script("ink-cli", f"""
printf '\\033[2mBrowser didn'"'"'t open? Use the url below to sign in\\033[22m\\n'
printf '\\033]8;;{url}\\033\\\\\\033[2m{url}\\033[22m\\033]8;;\\033\\\\\\n'
printf 'Paste\\033[1Ccode\\033[1Chere\\033[1Cif\\033[1Cprompted\\033[1C> '
read line
printf '%s\\n' "$line" >> "$HOME/got"
sleep 5
""")
        h = self.start(cli)
        self.assertEqual(h.frame(), {"type": "auth_url", "url": url})
        self.assertEqual(h.frame(), {"type": "need_code"})
        h.send("code", code="c0de#osc8")
        deadline = time.monotonic() + 10
        while not (self.home / "got").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual((self.home / "got").read_text(), "c0de#osc8\n")


class TimeoutTest(unittest.TestCase):
    def test_ten_minutes_is_the_limit_and_ends_with_timeout(self):
        from zb_agent_host import login
        self.assertEqual(login.TIMEOUT_S, 600)
        home = Path(tempfile.mkdtemp(prefix="zb-login-unit-"))
        self.addCleanup(shutil.rmtree, home, ignore_errors=True)
        out = []

        class Out:
            def emit(self, type_, **fields):
                out.append({"type": type_, **fields})

        read, write = os.pipe()
        token_r, token_w = os.pipe()
        self.addCleanup(os.close, token_r)
        stdin = os.fdopen(read, "r")
        self.addCleanup(stdin.close)
        os.write(write, b'{"v":1,"seq":1,"type":"start"}\n')
        run = login.Login(str(home), str(FAKE), Out(), token_w, timeout_s=1)
        started = time.monotonic()
        code = run.run(stdin)
        os.close(write)
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(code, 1)
        self.assertEqual(out[-1]["type"], "error")
        self.assertEqual(out[-1]["code"], "timeout")


if __name__ == "__main__":
    unittest.main()
