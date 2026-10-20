"""Non-live coverage of real_screen_check.py's `long-run` case (chat-drawer plan S5.6,
rev 16.20.10 and 16.20.11; RoseCat ae39e2a, 4990de9). The case is run exactly as the
orchestrator runs it on the user's screen, but on a private Xvfb (xsession.py, :200-:399),
against the built binary:

    python3 tests/e2e/xsession.py --xvfb -- env ZB_LONGRUN_BIN=zig-out/bin/zigBrowser \\
        python3 -m unittest -v test_real_screen_longrun

(from tests/manual). It must pass both replies: a 200 KiB reply with no spaces and a
200 KiB reply of words, each shown, folded by '-' within 1 s, reopened, and copied with a
click, Ctrl+A and Ctrl+C to exactly the original. It also keeps the script's guards: no
run without --confirm-user-permission, and an --out that is not empty is refused."""

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "real_screen_check.py"


def private_display() -> bool:
    match = re.fullmatch(r":(\d+)(\.\d+)?", os.environ.get("DISPLAY", ""))
    return bool(match) and 200 <= int(match.group(1)) <= 399


def binary() -> str:
    return str(Path(os.environ.get("ZB_LONGRUN_BIN", HERE.parents[1] / "zig-out" / "bin" / "zigBrowser")).resolve())


class LongRunOnPrivateXvfb(unittest.TestCase):
    def setUp(self):
        # Fail closed: never the user's display, and never a silent skip.
        self.assertTrue(private_display(), f"DISPLAY {os.environ.get('DISPLAY')!r} is not a private Xvfb (:200-:399)")
        self.assertTrue(Path(binary()).is_file(), f"no binary at {binary()}")

    def run_case(self, *extra, out=None):
        out = out or tempfile.mkdtemp(prefix="zb-longrun-out-")
        done = subprocess.run([sys.executable, str(SCRIPT), *extra, "--case", "long-run", "--bin", binary(),
                               "--out", out], capture_output=True, text=True, timeout=600)
        return done, Path(out)

    def test_the_long_run_case_passes_both_replies(self):
        done, out = self.run_case("--confirm-user-permission")
        report = done.stdout + done.stderr[-3000:]
        self.assertEqual(done.returncode, 0, report)
        for name in ("long-run-unbroken", "long-run-words"):
            line = [x for x in done.stdout.splitlines() if re.match(rf"^PASS\s+{name}\b", x)]
            self.assertEqual(len(line), 1, report)
            self.assertRegex(line[0], r"shown .*folded in 0\.\d\d s.*copied exactly 204800 characters", report)
        self.assertTrue((out / "long-run.rows.txt").is_file(), sorted(p.name for p in out.iterdir()))
        self.assertTrue((out / "long-run.stderr.txt").is_file())

    def test_no_run_without_the_users_permission(self):
        done, out = self.run_case()
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("--confirm-user-permission", done.stderr)
        self.assertEqual(list(out.iterdir()), [])

    def test_an_out_directory_that_is_not_empty_is_refused(self):
        out = Path(tempfile.mkdtemp(prefix="zb-longrun-out-"))
        (out / "left-over").write_text("x")
        done, _ = self.run_case("--confirm-user-permission", out=str(out))
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("not empty", done.stderr)


if __name__ == "__main__":
    unittest.main()
