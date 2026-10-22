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
  stat seam that shows only the home's inode as foreign; RoseCat 7750);
- the home's path is trusted only through a checked chain from / (RoseCat 7753): every directory above the home is
  owned by root or by us and writable by no one else, except a sticky one (like /tmp) whose next entry is root's or
  ours. With a home laid out like production (<data root>/zigbrowser/agent-home): a data root writable by others
  (an arbitrary unsafe XDG_DATA_HOME), a sticky data root whose app parent is another uid's, an app parent wider
  than 0755 or another uid's, a symlinked home and a symlinked ancestor are each refused, nothing made and nothing
  launched; so is a valid-looking app parent swapped in while the path is walked (an os.open seam at its open); a
  sticky data root holding our own app parent is accepted (a control);
- the paths the CLI gets must still name the checked directories right before the launch: a home swapped for a
  valid-looking one (scratchpad and tmp 0700, ours) when the CLI's environment is built (a login.cli_env seam) is
  refused, launching nothing, and the replacement is left as it is.
The trust anchor's owner is root (uid 0). In a user namespace real root shows as the overflow uid, so the rows read
it from / as this run sees it (a test-only seam, login.TRUST_ANCHOR_UID); production trusts only uid 0.
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
        p = mock.patch.object(login, "TRUST_ANCHOR_UID", os.stat("/").st_uid, create=True)
        p.start()
        self.addCleanup(p.stop)

    def use_home(self, home):
        self.close_master()
        self.home = home
        self.scratchpad = os.path.join(home, "scratchpad")
        self.dir = os.path.join(self.scratchpad, "tmp")
        self.login = login.Login(home, "/opt/claude", out=None, token_fd=-1)

    def deep_home(self, data_mode=0o700, parent_mode=0o700):
        """A fresh home laid out like production, <data root>/zigbrowser/agent-home (0700), made the sign-in's."""
        data = os.path.join(tempfile.mkdtemp(dir=self.tmp.name), "data")
        parent = os.path.join(data, "zigbrowser")
        home = os.path.join(parent, "agent-home")
        os.makedirs(home, 0o700)
        os.chmod(home, 0o700)
        os.chmod(parent, parent_mode)
        os.chmod(data, data_mode)
        self.use_home(home)
        return data, parent, home

    def foreign(self, path):
        """A seam over os.stat/lstat/fstat that shows only `path`'s inode with another uid; all else as it is."""
        st0 = os.lstat(path)

        class Foreign:
            def __init__(self, st):
                self.st = st

            def __getattr__(self, name):
                return self.st.st_uid + 1 if name == "st_uid" else getattr(self.st, name)

        def seam(real):
            def call(*args, **kw):
                st = real(*args, **kw)
                return Foreign(st) if (st.st_dev, st.st_ino) == (st0.st_dev, st0.st_ino) else st
            return call
        return mock.patch.multiple(os, stat=seam(os.stat), lstat=seam(os.lstat), fstat=seam(os.fstat))

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
                parent = os.path.dirname(path)
                real_open = os.open
                swapped = []

                def opener(name, flags, mode=0o777, *, dir_fd=None):  # only `component` itself, not a namesake
                    if (name == component and not swapped and dir_fd is not None
                            and os.path.lexists(parent) and os.path.samestat(os.fstat(dir_fd), os.lstat(parent))):
                        os.rename(path, path + f".seen{len(swapped)}")
                        os.mkdir(path, 0o700)
                        os.chmod(path, 0o700)
                        swapped.append(os.lstat(path).st_ino)
                    return real_open(name, flags, mode, dir_fd=dir_fd)
                with mock.patch.object(os, "open", side_effect=opener):
                    self.refused(f"a valid {component} swapped in before its open")
                self.assertEqual(len(swapped), 1, "the seam did not swap")
                after = os.lstat(path)  # the replacement is left as it was: not repaired, deleted or written
                self.assertEqual((after.st_ino, stat.S_IMODE(after.st_mode), os.listdir(path)),
                                 (swapped[0], 0o700, []), "the replacement was changed")
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
        with self.foreign(self.home):
            self.refused("a home owned by another uid")
        self.assertEqual(os.listdir(self.home), [], "something was made in the home")

    def test_an_ancestor_writable_by_others_is_refused_with_nothing_made(self):
        for mode in (0o777, 0o775, 0o757):
            with self.subTest(mode=oct(mode)):
                _, _, home = self.deep_home(data_mode=mode)
                self.refused(f"a data root of mode {oct(mode)}")
                self.assertEqual(os.listdir(home), [], "something was made in the home")

    def test_a_sticky_ancestor_is_trusted_only_for_our_own_entry(self):
        self.deep_home(data_mode=0o1777)  # a control: like /tmp, holding our own app parent
        self.login.spawn()
        self.assertEqual((self.seen[0]["scratchpad"], self.seen[0]["tmp"]), (self.VALID, self.VALID))
        self.seen.clear()
        _, parent, home = self.deep_home(data_mode=0o1777)
        with self.foreign(parent):
            self.refused("a sticky data root whose app parent is another uid's")
        self.assertEqual(os.listdir(home), [], "something was made in the home")

    def test_a_wide_or_foreign_app_parent_is_refused(self):
        _, _, home = self.deep_home(parent_mode=0o770)
        self.refused("an app parent of mode 0770")
        self.assertEqual(os.listdir(home), [], "something was made in the home")
        _, parent, home = self.deep_home()
        with self.foreign(parent):
            self.refused("an app parent owned by another uid")
        self.assertEqual(os.listdir(home), [], "something was made in the home")

    def test_a_symlinked_home_is_refused_unchanged(self):
        _, parent, home = self.deep_home()
        os.rmdir(home)
        target = self.elsewhere()
        os.chmod(target, 0o700)
        os.symlink(target, home)
        self.refused("a symlinked home")
        self.assertEqual((os.readlink(home), os.listdir(target)), (target, []), "changed on refusal")

    def test_a_symlinked_ancestor_is_refused(self):
        data, _, _ = self.deep_home()
        os.rename(data, data + ".real")
        os.symlink(data + ".real", data)
        self.refused("a symlinked data root")
        self.assertEqual(os.listdir(os.path.join(data + ".real", "zigbrowser", "agent-home")), [],
                         "something was made through the link")

    def test_an_ancestor_swapped_while_the_path_is_walked_is_refused_unchanged(self):
        data, parent, home = self.deep_home()
        real_open = os.open
        swapped = []

        def opener(name, flags, mode=0o777, *, dir_fd=None):
            if (name == "zigbrowser" and not swapped and dir_fd is not None
                    and os.path.samestat(os.fstat(dir_fd), os.lstat(data))):
                os.rename(parent, parent + ".seen")
                os.makedirs(home, 0o700)
                os.chmod(parent, 0o700)
                os.chmod(home, 0o700)
                swapped.append(os.lstat(parent).st_ino)
            return real_open(name, flags, mode, dir_fd=dir_fd)
        with mock.patch.object(os, "open", side_effect=opener):
            self.refused("an app parent swapped in while the path was walked")
        self.assertEqual(swapped, [os.lstat(parent).st_ino], "the seam did not swap, or the replacement was moved")
        self.assertEqual((os.listdir(parent), os.listdir(home)), (["agent-home"], []), "the replacement was written")

    def test_a_home_swapped_before_the_launch_is_refused(self):
        _, _, home = self.deep_home()
        real_cli_env = login.cli_env
        swapped = []

        def cli_env(*args, **kw):
            if not swapped:  # the paths the CLI gets now name a valid-looking home of someone else's choosing
                os.rename(home, home + ".checked")
                os.makedirs(os.path.join(home, "scratchpad", "tmp"), 0o700)
                for d in (home, os.path.join(home, "scratchpad"), os.path.join(home, "scratchpad", "tmp")):
                    os.chmod(d, 0o700)
                swapped.append(os.lstat(home).st_ino)
            return real_cli_env(*args, **kw)
        with mock.patch.object(login, "cli_env", side_effect=cli_env):
            self.refused("a home swapped before the launch")
        self.assertEqual(swapped, [os.lstat(home).st_ino], "the seam did not swap, or the replacement was moved")
        self.assertEqual(os.listdir(os.path.join(home, "scratchpad", "tmp")), [], "the replacement was written")

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
