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
import signal
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


def descendants(root: int) -> list[int]:
    """Every live descendant of `root`, by the ppid chain (the case starts the browser in
    a session of its own, so it is not in the script's process group)."""
    parents: dict[int, list[int]] = {}
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                with open(f"/proc/{entry}/stat") as f:
                    ppid = int(f.read().rsplit(")", 1)[1].split()[1])
            except (OSError, IndexError, ValueError):
                continue
            parents.setdefault(ppid, []).append(int(entry))
    found, todo = [], [root]
    while todo:
        for child in parents.get(todo.pop(), []):
            found.append(child)
            todo.append(child)
    return found


def setUpModule():
    # A child subreaper: whatever the script leaves behind (it starts the browser in a
    # session of its own) is re-parented to this process, so kill_all() finds it.
    import ctypes
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_CHILD_SUBREAPER)")


def reap() -> None:
    """Reaps every exited child (adopted orphans included)."""
    while True:
        try:
            if os.waitpid(-1, os.WNOHANG) == (0, 0):
                return
        except ChildProcessError:
            return


def still_running(grace: float) -> list[int]:
    """This test's live descendants once they had `grace` seconds to exit."""
    import time
    deadline = time.monotonic() + grace
    while True:
        reap()
        left = descendants(os.getpid())
        if not left or time.monotonic() >= deadline:
            return left
        time.sleep(0.1)


def kill_all() -> None:
    """Every process this test started, directly or not, with its process group: the
    script, the browser, netd, the helper and their X clients. Then reap them."""
    for pid in descendants(os.getpid()):
        for kill in (lambda p: os.killpg(os.getpgid(p), signal.SIGKILL), lambda p: os.kill(p, signal.SIGKILL)):
            try:
                kill(pid)
            except (ProcessLookupError, PermissionError):
                pass
    still_running(10.0)


def binary() -> str:
    return str(Path(os.environ.get("ZB_LONGRUN_BIN", HERE.parents[1] / "zig-out" / "bin" / "zigBrowser")).resolve())


class LongRunOnPrivateXvfb(unittest.TestCase):
    def setUp(self):
        # Fail closed: never the user's display, and never a silent skip.
        self.assertTrue(private_display(), f"DISPLAY {os.environ.get('DISPLAY')!r} is not a private Xvfb (:200-:399)")
        self.assertTrue(Path(binary()).is_file(), f"no binary at {binary()}")

    def run_case(self, *extra, out=None):
        """The script's result, and its --out (a directory removed after the test)."""
        if out is None:
            box = tempfile.TemporaryDirectory(prefix="zb-longrun-out-")
            self.addCleanup(box.cleanup)
            out = box.name
        proc = subprocess.Popen([sys.executable, str(SCRIPT), *extra, "--case", "long-run", "--bin", binary(),
                                 "--out", out], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                start_new_session=True)
        try:
            stdout, stderr = proc.communicate(timeout=600)
        except subprocess.TimeoutExpired:
            kill_all()
            stdout, stderr = proc.communicate()
            self.fail(f"the long-run case took over 600 s: {stdout[-2000:]}{stderr[-2000:]}")
        finally:
            leftover = still_running(10.0)  # the helper and netd exit just after the browser
            kill_all()
        self.assertEqual(leftover, [], "the script left processes running")
        return subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr), Path(out)

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
        box = tempfile.TemporaryDirectory(prefix="zb-longrun-out-")
        self.addCleanup(box.cleanup)
        out = Path(box.name)
        (out / "left-over").write_text("x")
        done, _ = self.run_case("--confirm-user-permission", out=str(out))
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("not empty", done.stderr)


if __name__ == "__main__":
    unittest.main()
