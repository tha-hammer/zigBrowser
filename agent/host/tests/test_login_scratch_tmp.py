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
  the effective uid (an os.geteuid seam: the namespace cannot make a foreign uid). A refused object is left exactly
  as it was (a snapshot of the wide tmp, and of a symlinked scratchpad's target, before and after);
- a scratchpad swapped for a link to elsewhere WHILE the sign-in makes its tmp (an os.mkdir seam that swaps it at
  that call) redirects nothing: nothing is made under the link's target and the CLI is not launched (RoseCat 7742);
- a REAL directory (0755, ours) put in place of a just-made scratchpad or tmp between its mkdir and its open (an
  os.mkdir seam that renames the new one away and makes the replacement) is refused, never repaired: it stays 0755
  with nothing made in it, and the CLI is not launched (RoseCat 7746's probe); so is a VALID-looking one (0700,
  ours) swapped in right before the open (an os.open seam): the object opened must be the one first seen;
- the home itself must be ours and writable by no one else (only then can no other uid rename the scratchpad after
  the check, the trust boundary for the window up to and during the CLI's run): a home writable by its group or by
  others is refused, with nothing made in it; so is a home owned by another uid while its children are ours (a
  stat seam that shows only the home's inode as foreign; RoseCat 7750).
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
        before = os.lstat(self.dir)
        self.refused("a tmp wider than 0700")
        after = os.lstat(self.dir)
        self.assertEqual((after.st_ino, stat.S_IMODE(after.st_mode)), (before.st_ino, 0o755), "it was repaired")

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
        before = (os.readlink(self.scratchpad), sorted(os.listdir(target)))
        self.refused("a symlinked scratchpad")
        self.assertEqual((os.readlink(self.scratchpad), sorted(os.listdir(target))), before, "changed on refusal")

    def replaced_at_mkdir(self, component):
        """An os.mkdir seam: right after the real mkdir of `component`, its new directory is renamed away and a
        different real directory of ours (0755) takes its name, before the sign-in can open it."""
        real_mkdir = os.mkdir
        path = self.scratchpad if component == "scratchpad" else self.dir
        swapped = []

        def mkdir(name, mode=0o777, *, dir_fd=None):
            real_mkdir(name, mode, dir_fd=dir_fd)
            if name == component and not swapped:
                os.rename(path, path + ".made")
                real_mkdir(path, 0o755)
                os.chmod(path, 0o755)
                swapped.append(os.lstat(path).st_ino)
        if component == "tmp":
            os.mkdir(self.scratchpad, 0o700)
        with mock.patch.object(os, "mkdir", side_effect=mkdir):
            self.refused(f"a real directory put in place of the just-made {component}")
        after = os.lstat(path)
        self.assertEqual(swapped, [after.st_ino], "the seam did not swap")
        self.assertEqual(stat.S_IMODE(after.st_mode), 0o755, "the replacement was repaired")
        self.assertEqual(os.listdir(path), [], "something was made in the replacement")

    def test_a_real_directory_replacing_the_new_scratchpad_is_refused_unchanged(self):
        self.replaced_at_mkdir("scratchpad")

    def test_a_real_directory_replacing_the_new_tmp_is_refused_unchanged(self):
        self.replaced_at_mkdir("tmp")

    def test_a_valid_directory_swapped_in_before_the_open_is_refused(self):
        for component in ("scratchpad", "tmp"):
            with self.subTest(component=component):
                path = self.scratchpad if component == "scratchpad" else self.dir
                real_open = os.open
                swapped = []

                def opener(name, flags, mode=0o777, *, dir_fd=None):
                    if name == component and not swapped:
                        os.rename(path, path + f".seen{len(swapped)}")
                        os.mkdir(path, 0o700)
                        os.chmod(path, 0o700)
                        swapped.append(os.lstat(path).st_ino)
                    return real_open(name, flags, mode, dir_fd=dir_fd)
                with mock.patch.object(os, "open", side_effect=opener):
                    self.refused(f"a valid {component} swapped in before its open")
                self.assertEqual(len(swapped), 1, "the seam did not swap")
                shutil.rmtree(self.scratchpad)
                if os.path.lexists(self.scratchpad + ".seen0"):
                    shutil.rmtree(self.scratchpad + ".seen0")

    def test_a_scratchpad_swapped_while_tmp_is_made_redirects_nothing(self):
        os.mkdir(self.scratchpad, 0o700)
        target = self.elsewhere()
        os.chmod(target, 0o700)
        real_mkdir = os.mkdir

        def mkdir(path, mode=0o777, *, dir_fd=None):
            if path == "tmp" and not os.path.islink(self.scratchpad):  # swap it right at this call
                os.rename(self.scratchpad, self.scratchpad + ".moved")
                os.symlink(target, self.scratchpad)
            return real_mkdir(path, mode, dir_fd=dir_fd)

        with mock.patch.object(os, "mkdir", side_effect=mkdir):
            self.refused("a scratchpad swapped for a link meanwhile")
        self.assertEqual(os.listdir(target), [], "something was made under the link's target")

    def test_a_home_writable_by_others_is_refused_with_nothing_made(self):
        for mode in (0o770, 0o707, 0o1777):
            with self.subTest(mode=oct(mode)):
                os.chmod(self.home, mode)
                self.refused(f"a home of mode {oct(mode)}")
                self.assertEqual(os.listdir(self.home), [], "something was made in the home")
        os.chmod(self.home, 0o700)

    def test_a_home_owned_by_another_uid_is_refused_with_nothing_made(self):
        home = os.lstat(self.home)

        class Foreign:  # the home's stat, but another uid's; every other field as it is
            def __init__(self, st):
                self.st = st

            def __getattr__(self, name):
                return self.st.st_uid + 1 if name == "st_uid" else getattr(self.st, name)

        def seam(real):
            def call(*args, **kw):
                st = real(*args, **kw)
                return Foreign(st) if (st.st_dev, st.st_ino) == (home.st_dev, home.st_ino) else st
            return call
        with mock.patch.multiple(os, stat=seam(os.stat), lstat=seam(os.lstat), fstat=seam(os.fstat)):
            self.refused("a home owned by another uid")
        self.assertEqual(os.listdir(self.home), [], "something was made in the home")

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
