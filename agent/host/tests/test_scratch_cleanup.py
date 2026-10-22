"""Setup's and the probe's throwaway trees are removed, a 0300 FIFO directory included (16bad65, both Macs: four
/private/tmp/zb-setup-run-*/zb-route-probe-*/zb-token dirs, mode 0300 and empty, outlived every run, because
token.FifoHandoff makes its directory write+search-only and both removals were shutil.rmtree(..., ignore_errors=True),
which cannot list it and says nothing; Linux's bwrap tmpfs had hidden it).

- FifoHandoff(..., remove_directory=True).close() (route_probe's throwaway one) removes the directory it created (the
  FIFO unlinked, then the directory), whether or not the wrapper ever opened the FIFO; a directory it did not create
  is left as it was; by default (a session's FIFO directory, contract.Route) the directory stays, empty and 0300;
- route_probe.run leaves nothing of its zb-route-probe-* scratch behind (Linux path, the SDK's query faked);
- setup's sandboxed runs leave nothing of their zb-setup-run-* scratch behind, even when the run left 0300
  directories in it (empty, and holding a file);
- a removal that still fails is reported on stderr with its path, never hidden;
- files.remove_tree never opens or removes anything through a symlink: an outside 0300 directory a link in the tree
  points at keeps its mode and its contents; a FIFO in the tree is unlinked, never opened (RoseCat 7418);
- FifoHandoff.close() is idempotent: a second close changes nothing and raises nothing (RoseCat 7418).

Precondition: an unprivileged owner cannot list a 0300 directory. Under a user namespace mapped to root
(CAP_DAC_OVERRIDE) that is false and the leak cannot show, so the cases skip there. Sends no signal.
Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_scratch_cleanup.
Unregistered until the green.
"""
import contextlib
import io
import os
import shutil
import stat
import tempfile
import threading
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)
import test_setup_darwin_r1 as r1

from zb_agent_host import files, route_probe, setup, token


def _dac_bites(root):
    probe = os.path.join(root, "dac-probe")
    os.mkdir(probe, 0o300)
    try:
        os.listdir(probe)
        return False
    except PermissionError:
        return True
    finally:
        os.rmdir(probe)


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="zb-scratch-cleanup-")
        self.addCleanup(self.force_remove, self.root)
        if not _dac_bites(self.root):
            self.skipTest("this process can list a 0300 directory (root or DAC override): the leak cannot show")
        self.addCleanup(mock.patch.stopall)

    @staticmethod
    def force_remove(path):
        """The test's own cleanup: open every directory (top-down, before os.walk descends) and remove the tree."""
        with contextlib.suppress(OSError):
            os.chmod(path, 0o700)
        for dirpath, dirnames, _files in os.walk(path):
            for d in dirnames:
                with contextlib.suppress(OSError):
                    os.chmod(os.path.join(dirpath, d), 0o700)
        shutil.rmtree(path, ignore_errors=True)

    def entries(self):
        return sorted(os.listdir(self.root))


class FifoHandoffClose(Base):
    def test_close_removes_its_directory_when_the_fifo_was_never_opened(self):
        d = os.path.join(self.root, "zb-token")
        h = token.FifoHandoff(d, "zb-probe-x", remove_directory=True)
        self.assertEqual(stat.S_IMODE(os.stat(d).st_mode), 0o300)
        h.close()
        self.assertFalse(os.path.lexists(d), "the 0300 directory outlived close()")

    def test_close_removes_its_directory_after_the_wrapper_read_the_token(self):
        d = os.path.join(self.root, "zb-token")
        h = token.FifoHandoff(d, "zb-probe-x", remove_directory=True)
        fd = os.open(h.path, os.O_RDONLY)  # as the wrapper does: open, unlink, read
        os.unlink(h.path)
        with os.fdopen(fd, "rb") as f:
            self.assertEqual(f.read(), b"zb-probe-x\n")
        h.close()
        self.assertFalse(os.path.lexists(d))

    def test_by_default_a_sessions_fifo_directory_stays_empty_and_0300(self):
        d = os.path.join(self.root, "token-fifo")
        h = token.FifoHandoff(d, "zb-probe-x")
        h.close()
        self.assertEqual(stat.S_IMODE(os.stat(d).st_mode), 0o300, "test_contract's session FIFO directory")
        os.chmod(d, 0o700)
        self.assertEqual(os.listdir(d), [])

    def test_close_twice_is_harmless(self):
        d = os.path.join(self.root, "zb-token")
        h = token.FifoHandoff(d, "zb-probe-x", remove_directory=True)
        h.close()
        h.close()
        self.assertFalse(os.path.lexists(d))
        self.assertEqual(self.entries(), [])

    def test_a_directory_it_did_not_create_is_left_alone(self):
        d = os.path.join(self.root, "shared")
        os.mkdir(d, 0o700)
        keep = os.path.join(d, "keep")
        open(keep, "w").close()
        h = token.FifoHandoff(d, "zb-probe-x", remove_directory=True)
        h.close()
        os.chmod(d, 0o700)
        self.assertEqual(os.listdir(d), ["keep"])


class RemoveTree(Base):
    def test_a_symlink_in_the_tree_is_removed_as_a_link_never_followed(self):
        outside = os.path.join(self.root, "outside")
        os.mkdir(outside, 0o700)
        open(os.path.join(outside, "keep"), "w").close()
        os.chmod(outside, 0o300)
        tree = os.path.join(self.root, "tree")
        os.mkdir(tree, 0o700)
        os.symlink(outside, os.path.join(tree, "link"))
        self.assertEqual(files.remove_tree(tree), [])
        self.assertFalse(os.path.lexists(tree))
        self.assertEqual(stat.S_IMODE(os.stat(outside).st_mode), 0o300, "the link's target was chmodded")
        os.chmod(outside, 0o700)
        self.assertEqual(os.listdir(outside), ["keep"])


    def test_a_fifo_in_the_tree_is_unlinked_never_opened(self):
        tree = os.path.join(self.root, "tree")
        os.mkdir(tree, 0o700)
        os.mkfifo(os.path.join(tree, "pipe"))
        os.chmod(tree, 0o300)
        done = []
        t = threading.Thread(target=lambda: done.append(files.remove_tree(tree)), daemon=True)
        t.start()
        t.join(5)
        if not done:  # it blocked opening the FIFO: release it, then fail
            fd = os.open(os.path.join(tree, "pipe"), os.O_WRONLY | os.O_NONBLOCK)
            os.close(fd)
            t.join(5)
        self.assertEqual(done, [[]], "remove_tree opened the FIFO or left something")
        self.assertFalse(os.path.lexists(tree))


class RouteProbeRun(Base):
    def test_run_leaves_no_scratch_behind(self):
        async def no_turn(**_kw):
            return
            yield  # an async generator that yields nothing

        mock.patch.object(tempfile, "tempdir", self.root).start()
        mock.patch.object(route_probe, "PLATFORM", "linux").start()
        mock.patch("claude_agent_sdk.query", side_effect=lambda **kw: no_turn(**kw)).start()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertFalse(route_probe.run("/w/zb-claude", "/c/claude"))
        self.assertEqual(self.entries(), [], "route_probe.run left its scratch behind")


class SetupRuns(Base):
    def setUp(self):
        super().setUp()
        mock.patch.object(tempfile, "tempdir", self.root).start()
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        self.seam = []

        @contextlib.contextmanager
        def setup_sandbox(scratch, ro_paths, command, *, loopback_port=None):
            self.seam.append(str(scratch))
            yield ["/usr/bin/sandbox-exec", "-f", f"{scratch}/p.sb", *command]

        mock.patch.object(setup.sandbox_macos, "setup_sandbox", setup_sandbox).start()

        def run(argv, **kwargs):  # the sandboxed run leaves 0300 trees in its HOME, as the probe's zb-token
            home = kwargs["env"]["HOME"]
            os.mkdir(os.path.join(home, "empty-0300"), 0o300)
            full = os.path.join(home, "full-0300")
            os.mkdir(full, 0o700)
            open(os.path.join(full, "f"), "w").close()
            os.chmod(full, 0o300)
            return setup.subprocess.CompletedProcess(argv, 0, stdout="2.1.0 (Claude Code)\n", stderr="")

        support.fake_setup_runs(setup, side_effect=run).start()

    def test_a_sandboxed_run_leaves_no_scratch_behind(self):
        setup.cli_version(r1.CLI)
        self.assertEqual(len(self.seam), 1)
        self.assertEqual(self.entries(), [], "setup's run scratch outlived the run")

    def test_a_removal_that_fails_is_reported_with_its_path(self):
        real_rmdir = os.rmdir

        def stuck(path, *a, **kw):
            if os.path.basename(str(path)).startswith("zb-setup-run-"):
                raise OSError(16, "Device or resource busy", str(path))
            return real_rmdir(path, *a, **kw)

        mock.patch.object(os, "rmdir", side_effect=stuck).start()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            setup.cli_version(r1.CLI)
        self.assertIn(self.seam[0], err.getvalue(), "a failed removal must name its path on stderr")


if __name__ == "__main__":
    unittest.main()
