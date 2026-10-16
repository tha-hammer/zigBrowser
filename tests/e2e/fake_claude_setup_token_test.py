"""The setup-token fake matches the real CLI's capture (chat-drawer plan S6,
prerequisite rev 3 blocker 12): tests/fixtures/agent/setup_token_transcript.json,
recorded by the orchestrator from Claude Code v2.1.301 on the real screen.

Run alone, like the gate:  python3 -m unittest -v fake_claude_setup_token_test
(from tests/e2e). The fake runs on a pty, as the login helper will run the CLI.
"""

import json
import os
import pty
import re
import select
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

HERE = Path(__file__).resolve().parent
FAKE = HERE / "fake_claude_setup_token.py"
TRANSCRIPT = HERE.parent / "fixtures" / "agent" / "setup_token_transcript.json"

PLACEHOLDERS = {
    "<CLIENT_ID>": r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
    "<CHALLENGE>": r"[A-Za-z0-9_-]{43}",
    "<STATE>": r"[A-Za-z0-9_-]{43}",
    "<TOKEN>": r"sk-ant-oat01-[A-Za-z0-9_-]{22,499}",
    "<REDACTED>": r".+",
    "<PASTED_CODE_MASKED>": r"\*+",
}
INVALID = "Invalid code. Please make sure the full code was copied."
FOREIGN = "That code is not from this sign-in. Paste the code shown after opening the address above."


def line_pattern(line):
    """A fixture line as a regex: literal text, each placeholder its shape."""
    parts = re.split("(" + "|".join(re.escape(p) for p in PLACEHOLDERS) + ")", line)
    return re.compile("".join(PLACEHOLDERS.get(p, re.escape(p)) for p in parts))


class Fake:
    """The fake on a pty, read line by line (CR LF from the pty's ONLCR)."""

    def __init__(self, home, argv=("setup-token",)):
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen(
            [str(FAKE), *argv],
            stdin=slave, stdout=slave, stderr=subprocess.PIPE,
            env={"HOME": str(home), "PATH": "/usr/bin:/bin"},
            start_new_session=True,
        )
        os.close(slave)
        self.buf = b""

    def line(self, timeout=10):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buf:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([self.master], [], [], left)[0]:
                raise AssertionError(f"no line from the fake within {timeout}s ({self.buf!r})")
            try:
                chunk = os.read(self.master, 4096)
            except OSError:
                chunk = b""
            if not chunk:
                raise AssertionError(f"the fake closed its terminal ({self.buf!r})")
            self.buf += chunk
        raw, self.buf = self.buf.split(b"\n", 1)
        return raw.rstrip(b"\r").decode("utf-8")

    def type(self, text):
        os.write(self.master, text.encode() + b"\r")

    def close(self):
        if self.master < 0:
            return
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=10)
        self.proc.stderr.close()
        os.close(self.master)
        self.master = -1


class FakeSetupTokenTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="zb-fake-setup-token-"))
        self.addCleanup(shutil.rmtree, self.home)
        self.transcript = json.loads(TRANSCRIPT.read_text(encoding="utf-8"))
        self.lines = self.transcript["lines"]

    def start(self, *argv):
        fake = Fake(self.home, argv or ("setup-token",))
        self.addCleanup(fake.close)
        return fake

    def codes(self):
        log = self.home / ".zb-fake-setup-token" / "codes.log"
        return log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    def read_until_prompt(self, fake):
        """The lines up to and including the prompt's trailing control line."""
        got = []
        while not got or got[-1] != self.lines[6]:
            got.append(fake.line())
        return got

    def test_fixture_holds_no_secret(self):
        text = TRANSCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("sk-ant", text)
        self.assertEqual(re.findall(r"[A-Za-z0-9_-]{40,}", text), [])
        self.assertEqual(self.transcript["redirect_kind"], "manual-code-page")

    def test_output_matches_the_capture_line_for_line(self):
        fake = self.start()
        got = self.read_until_prompt(fake)
        url = got[4]
        state = dict(parse_qsl(urlsplit(url).query))["state"]
        fake.type(f"fakecode-0123#{state}")
        while len(got) < len(self.lines):
            got.append(fake.line())
        self.assertEqual(len(got), len(self.lines))
        for i, (want, have) in enumerate(zip(self.lines, got)):
            self.assertRegex(have, "^" + line_pattern(want).pattern + "$", f"line {i}")
        self.assertEqual(fake.proc.wait(timeout=10), 0)
        self.assertEqual(self.codes(), [f"fakecode-0123#{state}"])

    def test_authorize_url_has_the_captured_parameters(self):
        fake = self.start()
        url = urlsplit(self.read_until_prompt(fake)[4])
        want = self.transcript["authorize_url"]
        self.assertEqual(f"{url.scheme}://{url.netloc}{url.path}", want["scheme_host_path"])
        params = parse_qsl(url.query, keep_blank_values=True)
        self.assertEqual([name for name, _ in params], want["param_names"])
        for name, value in want["fixed_values"].items():
            self.assertEqual(dict(params)[name], value, name)

    def test_state_differs_each_run(self):
        states = set()
        for _ in range(2):
            fake = self.start()
            states.add(dict(parse_qsl(urlsplit(self.read_until_prompt(fake)[4]).query))["state"])
            fake.close()
        self.assertEqual(len(states), 2)

    def test_a_code_without_both_parts_is_refused_and_asked_again(self):
        fake = self.start()
        state = dict(parse_qsl(urlsplit(self.read_until_prompt(fake)[4]).query))["state"]
        for bad in ("nohash", "#" + state, "code#"):
            fake.type(bad)
            self.assertEqual(fake.line(), "*" * len(bad))
            self.assertEqual(fake.line(), INVALID)
            self.assertEqual(fake.line(), self.lines[5])
            self.assertEqual(fake.line(), self.lines[6])
        self.assertIsNone(fake.proc.poll())
        self.assertEqual(self.codes(), ["nohash", "#" + state, "code#"])

    def test_another_sign_ins_state_is_refused_and_asked_again(self):
        fake = self.start()
        self.read_until_prompt(fake)
        fake.type("fakecode#" + "A" * 43)
        self.assertEqual(fake.line(), "*" * len("fakecode#" + "A" * 43))
        self.assertEqual(fake.line(), FOREIGN)
        self.assertEqual(fake.line(), self.lines[5])
        self.assertIsNone(fake.proc.poll())

    def test_prints_the_token_file_when_present(self):
        d = self.home / ".zb-fake-setup-token"
        d.mkdir(mode=0o700)
        planted = "sk-ant-oat01-ZBCANARY-planted-0123456789"
        (d / "token").write_text(planted + "\n", encoding="ascii")
        fake = self.start()
        state = dict(parse_qsl(urlsplit(self.read_until_prompt(fake)[4]).query))["state"]
        fake.type(f"c#{state}")
        got = [fake.line() for _ in range(4)]
        self.assertEqual(got[3], planted)

    def test_refuses_without_a_terminal(self):
        proc = subprocess.run(
            [str(FAKE), "setup-token"], stdin=subprocess.DEVNULL, capture_output=True,
            env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"}, timeout=10,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, b"")
        self.assertIn(b"must be a terminal", proc.stderr)

    def test_never_listens_on_a_port(self):
        fake = self.start()
        self.read_until_prompt(fake)
        fds = Path(f"/proc/{fake.proc.pid}/fd")
        sockets = [os.readlink(fd) for fd in fds.iterdir() if os.readlink(fd).startswith("socket:")]
        self.assertEqual(sockets, [])


if __name__ == "__main__":
    unittest.main()
