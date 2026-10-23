#!/usr/bin/env python3
r"""RED (unregistered; NavyCanyon 8974649e): the copy-to-Win10 driver must delete only a Win10 run folder it created.

tests/windows/win10_spike_run.py at 918957ef enters the Win10 try/finally BEFORE its `mkdir` succeeds, so a failed
create (here: the folder appeared after the earlier absence check, and `mkdir` fails because it exists) still
reaches remove_after_webview2 and its rmdir — deleting a folder this run did not create. The driver must take
ownership only after it created the previously absent folder; on a failed create it stages nothing, runs nothing,
calls no helper and sends no rmdir, and reports the failure.

Reuses the registered selftest (tests/windows/win10_spike_run_selftest.py: fake TEST-NET transport, netns), with its
fake ssh answering `mkdir` with "already exists" (rc 1) when ZB_FAKE_MKDIR_FAIL is set.
Run:  python3 -I tests/windows/win10_spike_run_mkdir_red_test.py
"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import win10_spike_run_selftest as st  # noqa: E402

FAKE_MKDIR = "  mkdir*) exit 0 ;;\n"
assert st._FAKE_SSH.count(FAKE_MKDIR) == 1
st._FAKE_SSH = st._FAKE_SSH.replace(
    FAKE_MKDIR,
    '  mkdir*) [ -n "${ZB_FAKE_MKDIR_FAIL:-}" ] && { echo "A subdirectory or file already exists." >&2; exit 1; }; exit 0 ;;\n')


class MkdirOwnership(st.Win10SpikeRun):
    def test_a_failed_create_of_an_appeared_folder_deletes_nothing(self):
        proc = self._run(ZB_FAKE_MKDIR_FAIL="1")
        self.assertEqual(proc.returncode, 1, self.out)
        self.assertIn("mkdir", self.out)
        mk = self._idx(lambda l: l.startswith("SSH10 ") and "mkdir" in l)
        self.assertGreaterEqual(mk, 0, "the create was attempted")
        after = self.lines[mk + 1:]
        self.assertEqual([l for l in after if l.startswith("SSH10 ")], [],
                         "after a failed create: no staging, no run, no helper census, no rmdir on Win10")
        self.assertEqual([l for l in after if l.startswith("SCP ")], [], "nothing staged")
        self.assertEqual(self._ssh(10, "rmdir"), [], "the folder this run did not create is not deleted")
        self.assertEqual(list(self.w10fs.iterdir()), [], "nothing reached the Win10 folder")
        self.assertEqual(len(self._ssh(11, "rmdir")), 1, "the Win11 build folder is still removed")


if __name__ == "__main__":
    suite = unittest.TestSuite([MkdirOwnership("test_a_failed_create_of_an_appeared_folder_deletes_nothing")])
    sys.exit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
