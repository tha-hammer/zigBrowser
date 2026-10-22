"""The Seatbelt write root must be the scratchpad's own real path (11b3ac4 on both Macs; RoseCat 7627).

The MS6.3 hard-gate run's helper was denied file-write-create on <home>/scratchpad/token-fifo, INSIDE its own
scratchpad: the case's homes lived under /tmp, which on macOS is a symlink to private/tmp. launch_spec bound
`-D SCRATCHPAD=/tmp/...` as given, Seatbelt compares the resolved /private/tmp/... path, so
`(subpath (param "SCRATCHPAD"))` matched nothing and every write was denied (option-B unified-log query, both
arches). dparams checked only the spelling (absolute, canonical, not the root).

dparams now accepts only an EXISTING directory whose spelling equals its os.path.realpath; it refuses (never
rewrites) a symlinked ancestor, a symlink leaf, a nonexistent path and a non-directory, with a fixed error that
names the field (SCRATCHPAD) and echoes neither the supplied nor the resolved path. The refusal comes before
anything is materialized or spawned: launch_spec and launch() raise it before _materialize_profile, and
setup_sandbox before it writes its per-run profile. A real directory is accepted exactly as given.

Plain: no process is started and no signal is sent.
Run: cd agent/host/tests && python3 -X dev -m unittest -v test_sandbox_macos_scratch_real. Unregistered until the
green."""
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HOST_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_DIR))

from zb_agent_host import options, sandbox_macos  # noqa: E402


class ScratchRealPath(unittest.TestCase):
    def setUp(self):
        self.base = os.path.realpath(tempfile.mkdtemp(prefix="zb-scratch-real-"))
        self.addCleanup(shutil.rmtree, self.base, True)
        self.real = os.path.join(self.base, "private-tmp")  # the target, like macOS's /private/tmp
        self.scratch = os.path.join(self.real, "run", "home", "scratchpad")
        os.makedirs(self.scratch)
        os.symlink(self.real, os.path.join(self.base, "tmp"))  # like macOS's /tmp -> private/tmp
        self.via_ancestor = os.path.join(self.base, "tmp", "run", "home", "scratchpad")
        self.leaf_link = os.path.join(self.base, "scratch-link")
        os.symlink(self.scratch, self.leaf_link)

    def refused(self, scratchpad):
        with self.assertRaises(ValueError) as cm:
            sandbox_macos.dparams(scratchpad=scratchpad)
        text = str(cm.exception)
        self.assertIn("SCRATCHPAD", text)
        for path in (scratchpad, self.base, os.path.realpath(scratchpad)):
            self.assertNotIn(path, text, "the error echoes a path")
        return text

    def test_a_real_existing_directory_is_accepted_exactly(self):
        self.assertEqual(sandbox_macos.dparams(scratchpad=self.scratch),
                         {sandbox_macos.SCRATCHPAD_PARAM: self.scratch})

    def test_a_symlinked_ancestor_like_macos_tmp_is_refused(self):
        self.assertTrue(os.path.isdir(self.via_ancestor), "the fixture resolves to the real scratchpad")
        self.refused(self.via_ancestor)

    def test_a_symlink_leaf_is_refused(self):
        self.refused(self.leaf_link)

    def test_a_nonexistent_path_is_refused(self):
        self.refused(os.path.join(self.real, "run", "home", "not-yet"))

    def test_a_non_directory_is_refused(self):
        f = os.path.join(self.real, "a-file")
        Path(f).write_text("x")
        self.refused(f)

    def test_launch_spec_refuses_before_any_profile_is_materialized(self):
        home = options.AgentHome(os.path.join(self.base, "tmp", "run", "home"))  # home.scratchpad = via_ancestor
        backend = sandbox_macos.MacSeatbeltBackend(52345)
        with mock.patch.object(sandbox_macos, "_materialize_profile",
                               side_effect=AssertionError("a profile was materialized")):
            with self.assertRaises(ValueError):
                backend.launch_spec(home)
            with self.assertRaises(ValueError):
                with backend.launch(home):
                    self.fail("launch() yielded a spec for a symlinked scratchpad")

    def test_setup_sandbox_refuses_before_writing_its_profile(self):
        before = sorted(os.listdir(self.real))
        with self.assertRaises(ValueError):
            with sandbox_macos.setup_sandbox(self.via_ancestor, [], ["/x/cli"]):
                self.fail("setup_sandbox yielded an argv for a symlinked scratch")
        self.assertEqual(sorted(os.listdir(self.real)), before)
        self.assertEqual(os.listdir(self.scratch), [], "a profile was written under the scratch")


if __name__ == "__main__":
    unittest.main()
