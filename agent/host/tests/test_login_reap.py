"""The login tests' cleanup reaps the CLI, not only the helper (orchestrator tidy-up, 2026-10-20).

The helper runs the CLI in its own session, and only the helper's own ending kills that session.
A test that ends while the sign-in is still running (an assertion failed, or the test needed only
the first frames) is cleaned up by Login.kill; if that SIGKILLs the helper, the helper's ending
never runs and the CLI is orphaned. Four `slow-cli` loops from test_login_contract's red lived
16 hours that way, waiting forever for a file in a deleted home. Run the module alone, as the
gate does."""

import os
import shutil
import signal
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_login import URL, Login  # noqa: E402


def alive(pid):
    """True while `pid` runs (a zombie, already dead, is not alive)."""
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (FileNotFoundError, ProcessLookupError):
        return False


class ReapTest(unittest.TestCase):
    def test_cleanup_mid_sign_in_leaves_no_cli_behind(self):
        home = Path(tempfile.mkdtemp(prefix="zb-login-reap-"))
        self.addCleanup(shutil.rmtree, home, ignore_errors=True)
        cli = home / "forever-cli"
        cli.write_text(f"""#!/bin/sh
echo $$ > "$HOME/cli.pid"
printf '%s\\n' '{URL.format(state="reap")}'
while :; do sleep 0.05; done
""")
        cli.chmod(0o700)
        h = Login(self, home, cli)
        h.send("start")
        self.assertEqual(h.frame()["type"], "auth_url")
        deadline = time.monotonic() + 10
        while not (home / "cli.pid").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        pid = int((home / "cli.pid").read_text())
        # This test's own safety net, so the red does not leak what it proves leaks.
        self.addCleanup(lambda: alive(pid) and os.killpg(pid, signal.SIGKILL))
        self.assertTrue(alive(pid), "the CLI is running before the cleanup")

        h.kill()  # what the test cleanup does when a test ends mid-sign-in

        deadline = time.monotonic() + 5
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(alive(pid), "the CLI outlived the cleanup (orphaned in its own session)")


if __name__ == "__main__":
    unittest.main()
