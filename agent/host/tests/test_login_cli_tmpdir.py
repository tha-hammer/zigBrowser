"""The sign-in CLI's temp directories live inside the agent home's scratchpad (RoseCat 0c476b8 / 7717 advisory, after
24f8d49 on both Macs).

login.cli_env builds the environment of `claude setup-token` (the one-shot sign-in, S6). It set neither TMPDIR nor
CLAUDE_CODE_TMPDIR, so the CLI fell back to /tmp for its temp files and for its own per-uid temp directory
(`claude-<uid>`): under the macOS sign-in profile, whose only write root is the home's scratchpad, those writes are
denied, as the chat CLI's `mkdir /tmp/claude-501` was on both Macs (BlueBeaver 7714).

login.cli_env(home):
- sets TMPDIR to the home's scratchpad/tmp (options.AgentHome(home).tmp);
- sets CLAUDE_CODE_TMPDIR to exactly the same directory;
- both are inside the scratchpad (the profile's only write root);
- neither comes from the helper's own environment: an ambient TMPDIR or CLAUDE_CODE_TMPDIR elsewhere is not used.
Pure Python: no process, no signal.
Run: cd agent/host/tests && unshare --map-current-user --pid --fork --kill-child --mount-proc \\
  sh -c '"$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v test_login_cli_tmpdir; exit $?'
Unregistered until the green."""
import os
import tempfile
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import login, options


class LoginCliTmpdir(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = self.tmp.name
        self.want = str(options.AgentHome(self.home).tmp)

    def test_tmpdir_is_the_scratchpads_tmp(self):
        self.assertEqual(login.cli_env(self.home).get("TMPDIR"), self.want)

    def test_the_clis_own_temp_dir_is_the_same_directory(self):
        self.assertEqual(login.cli_env(self.home).get("CLAUDE_CODE_TMPDIR"), self.want)

    def test_both_are_inside_the_scratchpad(self):
        scratchpad = str(options.AgentHome(self.home).scratchpad) + os.sep
        env = login.cli_env(self.home)
        for name in ("TMPDIR", "CLAUDE_CODE_TMPDIR"):
            with self.subTest(name=name):
                self.assertTrue((env.get(name) or "").startswith(scratchpad), env.get(name))

    def test_no_ambient_value_is_used(self):
        with mock.patch.dict(os.environ, {"TMPDIR": "/elsewhere", "CLAUDE_CODE_TMPDIR": "/elsewhere"}):
            env = login.cli_env(self.home)
        self.assertEqual((env.get("TMPDIR"), env.get("CLAUDE_CODE_TMPDIR")), (self.want, self.want))


if __name__ == "__main__":
    unittest.main()
