"""The exchange boundary is the CLI's, not the helper's (RoseCat 6239 SHOULD on b499cd7; bead
zigBrowser-zgx; plan rev 16.18.9).

login.py ends a sign-in with `error exchange` when "OAuth error" or "Press Enter to retry"
follows the typed code. Today "follows" means: after the helper's read offset at the moment it
wrote the code (`typed_at`). Bytes the CLI printed before it read the code, but which the helper
had not read yet, then count as the CLI's answer to it. The CLI's own boundary is exact and
visible: it echoes a '*' for each character as it reads the code (the real 2.1.294 does, and so
does the fake). Here a CLI prints OAuth-looking lines after its prompt but before it reads the
code (which the app sent early, so the helper types it the moment the prompt appears); only
then does it read, echo and succeed. The sign-in must end `done`.

Run the module alone, as the gate does."""

import shutil
import tempfile
import time
import unittest
from pathlib import Path

import test_login as tl


class BoundaryTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="zb-login-boundary-"))
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)
        (self.home / ".claude").mkdir()

    def test_lines_the_cli_printed_before_reading_the_code_do_not_end_it(self):
        self.late_noise(pause_after_echo=0)

    def test_and_not_while_the_cli_works_after_its_echo(self):
        # The echo, then a pause (the real exchange takes a moment) before the token: a
        # boundary taken anywhere before the echo would count the early lines here.
        self.late_noise(pause_after_echo=1.0)

    def late_noise(self, pause_after_echo):
        cli = self.home / "late-noise-cli"
        cli.write_text(f"""#!/bin/sh
stty -echo
printf '%s\\n' "{tl.URL.format(state='late')}"
printf 'Paste\\033[1Ccode\\033[1Chere\\033[1Cif\\033[1Cprompted\\033[1C> '
sleep 0.5
printf 'OAuth\\033[1Cerror:\\033[1Cnot\\033[1Cyet\\nPress\\033[1CEnter\\033[1Cto\\033[1Cretry.\\n'
read line
printf '%s\\n' "$(printf '%s' "$line" | tr -c '\\n' '*')"
sleep {pause_after_echo}
printf '\\342\\234\\223 Long-lived authentication token created successfully!\\n'
printf 'Your OAuth token (valid for 1 year):\\n{tl.CANARY}\\n'
sleep 5
""", encoding="utf-8")
        cli.chmod(0o700)
        h = tl.Login(self, self.home, cli)
        h.send("start")
        self.assertEqual(h.frame()["type"], "auth_url")
        h.send("code", code="c0de#late")  # early: the helper types it the moment the prompt shows
        self.assertEqual(h.frame(), {"type": "need_code"})
        started = time.monotonic()
        frame = h.frame(timeout=10)
        self.assertEqual(frame, {"type": "done"},
                         f"the CLI's pre-read lines ended the sign-in ({time.monotonic() - started:.1f}s): {frame}")
        code, _err, token = h.finish()
        self.assertEqual((code, token), (0, tl.CANARY.encode()))


if __name__ == "__main__":
    unittest.main()
