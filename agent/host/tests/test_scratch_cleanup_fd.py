"""The scratch removal holds file descriptors and never escapes its tree (RoseCat 7421 BLOCKED 4801844: remove_tree did
lstat(d) and then a path chmod(d, 0700); a sandboxed CLI that swaps d for a symlink between the two gets an OUTSIDE
directory chmodded 0700. And its report echoed descendant names, which the CLI chooses and could fill with the token).

- a directory swapped for a symlink to an outside 0300 directory right after the remover looked at it: the outside
  directory keeps its mode and its file, and the tree is still removed (the link unlinked as a link); both for a
  0700 and for a 0300 (needs-opening) victim;
- a token-named entry that cannot be removed: setup's stderr names the scratch root and a count, never the token;
- token.FifoHandoff on a path that is a symlink to an outside directory refuses and changes nothing there; on this
  user's existing real directory it works and leaves the directory in place on close.

Same precondition as test_scratch_cleanup (the cases skip where a 0300 directory can be listed). Sends no signal.
Run: cd agent/host/tests && python -X dev -m unittest -v test_scratch_cleanup_fd. Unregistered until the green.
"""
import contextlib
import io
import os
import stat
import tempfile
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)
import test_scratch_cleanup as cleanup

from zb_agent_host import files, setup, token

TOKEN = "zb-probe-" + "a1b2c3d4e5f6" * 4


class Base(cleanup.Base):
    def outside(self):
        d = os.path.join(self.root, "outside")
        os.mkdir(d, 0o700)
        open(os.path.join(d, "keep"), "w").close()
        os.chmod(d, 0o300)
        return d

    def assert_outside_untouched(self, d):
        self.assertEqual(stat.S_IMODE(os.stat(d).st_mode), 0o300, "the outside directory was chmodded")
        os.chmod(d, 0o700)
        self.assertEqual(os.listdir(d), ["keep"])


class SwapRace(Base):
    def swap_after_first_look(self, victim, target):
        """Wraps os.stat and os.lstat: right after the first look at `victim` returns (a real directory), `victim`
        becomes a symlink to `target`, as a live sandboxed CLI could do."""
        state = {"swapped": False}
        real_stat, real_lstat = os.stat, os.lstat

        def swap():
            if not state["swapped"]:
                state["swapped"] = True
                os.chmod(victim, 0o700)
                os.rmdir(victim)
                os.symlink(target, victim)

        def is_victim(p, dir_fd):
            name = os.fsdecode(p)
            return os.path.basename(name) == "victim" and (dir_fd is not None or os.path.dirname(name))

        def stat_(p, *a, dir_fd=None, follow_symlinks=True, **kw):
            r = real_stat(p, *a, dir_fd=dir_fd, follow_symlinks=follow_symlinks, **kw)
            if is_victim(p, dir_fd) and stat.S_ISDIR(r.st_mode):
                swap()
            return r

        def lstat_(p, *a, dir_fd=None, **kw):
            r = real_lstat(p, *a, dir_fd=dir_fd, **kw)
            if is_victim(p, dir_fd) and stat.S_ISDIR(r.st_mode):
                swap()
            return r

        mock.patch.object(os, "stat", side_effect=stat_).start()
        mock.patch.object(os, "lstat", side_effect=lstat_).start()
        return state

    def run_swap(self, victim_mode):
        outside = self.outside()
        tree = os.path.join(self.root, "tree")
        os.mkdir(tree, 0o700)
        victim = os.path.join(tree, "victim")
        os.mkdir(victim, victim_mode)
        state = self.swap_after_first_look(victim, outside)
        files.remove_tree(tree)
        mock.patch.stopall()
        self.assertTrue(state["swapped"], "the race was exercised")
        self.assert_outside_untouched(outside)
        self.assertFalse(os.path.lexists(tree), "the tree (and the swapped-in link) is removed")

    def test_a_0700_directory_swapped_for_a_symlink(self):
        self.run_swap(0o700)

    def test_a_0300_directory_swapped_for_a_symlink(self):
        self.run_swap(0o300)


class TokenFreeReport(Base):
    def test_a_token_named_entry_that_will_not_go_is_reported_without_its_name(self):
        mock.patch.object(tempfile, "tempdir", self.root).start()
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        seam = []

        @contextlib.contextmanager
        def setup_sandbox(scratch, ro_paths, command, *, loopback_port=None):
            seam.append(str(scratch))
            yield ["/usr/bin/sandbox-exec", *command]

        mock.patch.object(setup.sandbox_macos, "setup_sandbox", setup_sandbox).start()

        def run(argv, **kwargs):
            open(os.path.join(kwargs["env"]["HOME"], TOKEN), "w").close()
            return setup.subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        support.fake_setup_runs(setup, side_effect=run).start()
        real_unlink = os.unlink

        def stuck(p, *a, **kw):
            if TOKEN in os.fsdecode(p):
                raise OSError(16, f"Device or resource busy: {os.fsdecode(p)}")
            return real_unlink(p, *a, **kw)

        mock.patch.object(os, "unlink", side_effect=stuck).start()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            setup.cli_version("/opt/claude")
        mock.patch.stopall()
        text = err.getvalue()
        self.assertIn(seam[0], text, "the failure is reported, with the scratch root")
        self.assertNotIn("zb-probe-", text)
        self.assertNotIn(TOKEN[9:21], text, "token bytes reached stderr through a file name")
        os.unlink(os.path.join(seam[0], TOKEN))


class FifoHandoffDirectory(Base):
    def test_a_symlinked_directory_is_refused_and_untouched(self):
        outside = self.outside()
        link = os.path.join(self.root, "zb-token")
        os.symlink(outside, link)
        with self.assertRaises(OSError):
            token.FifoHandoff(link, "zb-probe-x")
        self.assert_outside_untouched(outside)

    def test_this_users_existing_directory_works_and_stays(self):
        d = os.path.join(self.root, "fifo-dir")
        os.mkdir(d, 0o700)
        h = token.FifoHandoff(d, "zb-probe-x")
        h.close()
        self.assertTrue(os.path.isdir(d), "a directory it did not make is not its to remove")


if __name__ == "__main__":
    unittest.main()
