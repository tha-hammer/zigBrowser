"""The CLI's per-uid temp directory lives inside the agent home's scratchpad (24f8d49 on both Macs, BlueBeaver 7714).

The pinned CLI (2.1.294) makes its own per-uid temp directory, `claude-<uid>`, under `CLAUDE_CODE_TMPDIR` when that
is set, and otherwise under /tmp: under the generated Seatbelt profile, whose only write root is the home's
scratchpad, `mkdir /tmp/claude-501` was denied (EPERM) and the CLI exited before its first request. cli_env set
TMPDIR to the scratchpad's tmp but not CLAUDE_CODE_TMPDIR.

The CLI's environment (options.build(...).env, which is options.cli_env):
- holds CLAUDE_CODE_TMPDIR, equal to TMPDIR: the home's scratchpad/tmp;
- that directory is inside the scratchpad (the profile's write root);
- a token route may not set it (it is part of the fixed CLI environment, like HOME and TMPDIR).
Pure Python: no process, no signal.
Run: cd agent/host/tests && unshare --map-current-user --pid --fork --kill-child --mount-proc \\
  sh -c '"$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v test_cli_env_tmpdir; exit $?'
Unregistered until the green."""
import os
import tempfile
import unittest
from pathlib import Path

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import options


class CliTmpdir(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = options.AgentHome(self.tmp.name)

    def env(self, route_env=None):
        return options.build(self.home, route_env=route_env or {}).env

    def test_the_clis_own_temp_dir_is_the_scratchpads_tmp(self):
        env = self.env()
        self.assertEqual(env.get("CLAUDE_CODE_TMPDIR"), str(self.home.scratchpad / "tmp"))
        self.assertEqual(env.get("CLAUDE_CODE_TMPDIR"), env["TMPDIR"])

    def test_it_is_inside_the_scratchpad_the_only_write_root(self):
        value = self.env().get("CLAUDE_CODE_TMPDIR") or ""
        self.assertTrue(value.startswith(str(self.home.scratchpad) + os.sep), value)
        self.assertEqual(Path(value).parent, self.home.scratchpad)

    def test_a_route_may_not_set_it(self):
        with self.assertRaises(ValueError):
            self.env({"CLAUDE_CODE_TMPDIR": "/tmp"})


if __name__ == "__main__":
    unittest.main()
