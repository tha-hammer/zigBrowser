"""The sign-in makes sure its CLI's temp directory exists before it launches the CLI (BlueBeaver 7735 follow-up to
4f326ee; RoseCat 0c476b8).

4f326ee points the sign-in CLI's TMPDIR and CLAUDE_CODE_TMPDIR at <home>/scratchpad/tmp. If that directory does not
exist yet when `claude setup-token` starts, the CLI cannot make its temp files or its per-uid temp dir in it.
Login.spawn therefore, before it launches the CLI:
- creates <home>/scratchpad/tmp (and the scratchpad) when missing, so it is a directory when the CLI starts;
- creates it owner-only (0700) and ours: nothing wider than the profile's write root needs;
- leaves an existing 0700 directory as it is (a control);
- refuses a <home>/scratchpad/tmp that is a symlink: the CLI is never launched (OSError, which run() reports as
  "the Claude CLI could not start"), so a link cannot move its temp files out of the scratchpad.
subprocess.Popen is a recorder (no process is started), and os.kill / os.killpg are patched to raise; the fake
process has no pid and has already ended. Run: cd agent/host/tests && unshare --map-current-user --pid --fork \\
  --kill-child --mount-proc sh -c '"$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v test_login_scratch_tmp; exit $?'
Unregistered until the green."""
import os
import stat
import tempfile
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import login


class FakeProc:
    pid = None  # never a pid a signal could reach

    def poll(self):
        return 0

    def wait(self, timeout=None):
        return 0


class LoginScratchTmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = self.tmp.name
        self.dir = os.path.join(self.home, "scratchpad", "tmp")
        self.seen = []
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached"))
            p.start()
            self.addCleanup(p.stop)

        def popen(argv, **kw):
            st = os.lstat(self.dir) if os.path.lexists(self.dir) else None
            self.seen.append({"is_dir": st is not None and stat.S_ISDIR(st.st_mode),
                              "mode": stat.S_IMODE(st.st_mode) if st else None,
                              "uid": st.st_uid if st else None,
                              "tmpdir": kw["env"].get("TMPDIR")})
            return FakeProc()

        p = mock.patch.object(login.subprocess, "Popen", side_effect=popen)
        p.start()
        self.addCleanup(p.stop)
        self.login = login.Login(self.home, "/opt/claude", out=None, token_fd=-1)
        self.addCleanup(self.close_master)

    def close_master(self):
        if self.login.master >= 0:
            os.close(self.login.master)
            self.login.master = -1

    def test_a_missing_tmp_is_a_directory_when_the_cli_starts(self):
        self.login.spawn()
        self.assertEqual(len(self.seen), 1)
        self.assertEqual(self.seen[0]["tmpdir"], self.dir)
        self.assertTrue(self.seen[0]["is_dir"], "the CLI started with no temp directory")

    def test_it_is_created_owner_only_and_ours(self):
        self.login.spawn()
        self.assertEqual((self.seen[0]["mode"], self.seen[0]["uid"]), (0o700, os.getuid()))

    def test_an_existing_tmp_is_left_as_it_is(self):
        os.makedirs(self.dir, 0o700)
        os.chmod(self.dir, 0o700)
        before = os.lstat(self.dir)
        self.login.spawn()
        after = os.lstat(self.dir)
        self.assertEqual((after.st_ino, stat.S_IMODE(after.st_mode)), (before.st_ino, 0o700))
        self.assertTrue(self.seen and self.seen[0]["is_dir"])

    def test_a_symlinked_tmp_is_refused_and_the_cli_never_starts(self):
        elsewhere = tempfile.mkdtemp(prefix="zb-login-elsewhere-")
        self.addCleanup(os.rmdir, elsewhere)
        os.makedirs(os.path.dirname(self.dir))
        os.symlink(elsewhere, self.dir)
        with self.assertRaises(OSError):
            self.login.spawn()
        self.assertEqual(self.seen, [], "the CLI was launched with a symlinked temp directory")


if __name__ == "__main__":
    unittest.main()
