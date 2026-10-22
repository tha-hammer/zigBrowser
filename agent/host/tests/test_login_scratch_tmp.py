"""The sign-in makes sure its CLI's temp directory exists before it launches the CLI (BlueBeaver 7735 follow-up to
4f326ee; RoseCat 0c476b8).

4f326ee points the sign-in CLI's TMPDIR and CLAUDE_CODE_TMPDIR at <home>/scratchpad/tmp. If that directory does not
exist yet when `claude setup-token` starts, the CLI cannot make its temp files or its per-uid temp dir in it.
Login.spawn therefore, before it launches the CLI:
- creates <home>/scratchpad and <home>/scratchpad/tmp when missing; at the CLI's launch BOTH are real directories,
  owned by the effective uid, mode 0700 (what setup.ensure_home makes and checks);
- leaves an existing valid (0700, ours) pair as it is (a control);
- refuses any existing invalid state, launching nothing (OSError, which run() reports as "the Claude CLI could not
  start"), never following or repairing it (RoseCat 7739): tmp a symlink, tmp wider than 0700, tmp a regular file,
  tmp a FIFO (never opened), the scratchpad itself a symlink, the scratchpad wider than 0700, and a pair not owned by
  the effective uid (an os.geteuid seam: the namespace cannot make a foreign uid).
subprocess.Popen is a recorder (no process is started), and os.kill / os.killpg are patched to raise; the fake
process has no pid and has already ended. Run: cd agent/host/tests && unshare --map-current-user --pid --fork \\
  --kill-child --mount-proc sh -c '"$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v test_login_scratch_tmp; exit $?'
Unregistered until the green."""
import os
import shutil
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
        self.scratchpad = os.path.join(self.home, "scratchpad")
        self.dir = os.path.join(self.scratchpad, "tmp")
        self.seen = []
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached"))
            p.start()
            self.addCleanup(p.stop)

        def popen(argv, **kw):
            def look(path):
                st = os.lstat(path) if os.path.lexists(path) else None
                return (st is not None and stat.S_ISDIR(st.st_mode), stat.S_IMODE(st.st_mode) if st else None,
                        st.st_uid if st else None)
            self.seen.append({"scratchpad": look(self.scratchpad), "tmp": look(self.dir),
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

    VALID = (True, 0o700, os.geteuid())

    def test_a_missing_pair_is_made_valid_before_the_cli_starts(self):
        self.login.spawn()
        self.assertEqual(len(self.seen), 1)
        self.assertEqual(self.seen[0]["tmpdir"], self.dir)
        self.assertEqual((self.seen[0]["scratchpad"], self.seen[0]["tmp"]), (self.VALID, self.VALID))

    def test_a_missing_tmp_under_a_valid_scratchpad_is_made_valid(self):
        os.mkdir(self.scratchpad, 0o700)
        self.login.spawn()
        self.assertEqual((self.seen[0]["scratchpad"], self.seen[0]["tmp"]), (self.VALID, self.VALID))

    def test_an_existing_valid_pair_is_left_as_it_is(self):
        os.makedirs(self.dir, 0o700)
        os.chmod(self.scratchpad, 0o700)
        os.chmod(self.dir, 0o700)
        before = (os.lstat(self.scratchpad).st_ino, os.lstat(self.dir).st_ino)
        self.login.spawn()
        self.assertEqual((os.lstat(self.scratchpad).st_ino, os.lstat(self.dir).st_ino), before)
        self.assertEqual((self.seen[0]["scratchpad"], self.seen[0]["tmp"]), (self.VALID, self.VALID))

    def refused(self, why):
        with self.assertRaises(OSError):
            self.login.spawn()
        self.assertEqual(self.seen, [], f"the CLI was launched with {why}")

    def elsewhere(self):
        d = tempfile.mkdtemp(prefix="zb-login-elsewhere-")
        self.addCleanup(shutil.rmtree, d, True)
        return d

    def test_a_symlinked_tmp_is_refused(self):
        os.mkdir(self.scratchpad, 0o700)
        os.symlink(self.elsewhere(), self.dir)
        self.refused("a symlinked tmp")

    def test_a_tmp_wider_than_0700_is_refused(self):
        os.makedirs(self.dir, 0o700)
        os.chmod(self.dir, 0o755)
        self.refused("a tmp wider than 0700")

    def test_a_tmp_that_is_a_regular_file_is_refused(self):
        os.mkdir(self.scratchpad, 0o700)
        with open(self.dir, "w"):
            pass
        self.refused("a tmp that is a regular file")

    def test_a_tmp_that_is_a_fifo_is_refused_without_opening_it(self):
        os.mkdir(self.scratchpad, 0o700)
        os.mkfifo(self.dir, 0o600)  # never opened here: an open would block the test
        self.refused("a tmp that is a FIFO")

    def test_a_symlinked_scratchpad_is_refused(self):
        target = self.elsewhere()
        os.mkdir(os.path.join(target, "tmp"), 0o700)
        os.chmod(target, 0o700)
        os.symlink(target, self.scratchpad)
        self.refused("a symlinked scratchpad")

    def test_a_scratchpad_wider_than_0700_is_refused(self):
        os.makedirs(self.dir, 0o700)
        os.chmod(self.scratchpad, 0o755)
        self.refused("a scratchpad wider than 0700")

    def test_a_pair_not_owned_by_the_effective_uid_is_refused(self):
        os.makedirs(self.dir, 0o700)
        os.chmod(self.scratchpad, 0o700)
        with mock.patch.object(os, "geteuid", return_value=os.geteuid() + 1):
            self.refused("a pair owned by another uid")


if __name__ == "__main__":
    unittest.main()
