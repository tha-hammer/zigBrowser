"""The PID-namespace wrappers of the agent-host gate steps keep the test's exit status, and contain what it starts
(RoseCat 7647 BLOCKED 8413992: `sh -c 'sh -c "...; :"; :'` turned every unittest failure into rc 0, so those steps
could not fail).

For each wrapped step of build.zig (the four setup-darwin units, test_contract, test_chat_redact, test_hook_net), its
EXACT command string is decoded from build.zig and run the way zig runs it (sh -c, cwd = the tree root, no display),
with ZB_AGENT_HOST_PYTHON (which tools/agent_host_env.sh --check honours) naming a stand-in "python" that records its
PID namespace and parent pid, leaves a marked background sleeper behind, and exits with a fixed status:
- a stand-in exiting 37 makes the whole command exit 37, and one exiting 0 makes it exit 0;
- the stand-in ran in a PID namespace that is not this test's, and with our own uid (--map-current-user, not root);
- its parent pid is above 1 (setup-darwin's parent-watch row passes --browser-pid os.getppid());
- test_contract's stand-in sees ZB_OUTER_PIDNS_FD (the launcher's held outer namespace, for pidns_guard), and its
  parent is that namespace's pid 1;
- once the command has returned, the marked sleeper is gone (--kill-child: the namespace's teardown ends it).
No signal is sent by this test; the only signals are the namespace teardown's, inside the namespace.
It runs every step command, so it runs only inside an OUTER private PID namespace (an unwrapped step, as in the
red, then reaches no further than that namespace): cd tests/e2e && unshare --user --map-root-user --pid --fork \\
  --kill-child --mount-proc sh -c 'setsid python3 -X dev -m unittest -v test_gate_step_wrappers; exit $?'
Unregistered until the green."""
import os
import re
import secrets
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SETUP_DARWIN = ("test_setup_darwin", "test_setup_darwin_r1", "test_setup_darwin_tmpdir", "test_setup_darwin_r1_v6")
STANDIN = """#!/bin/sh
{{ echo "ns=$(readlink /proc/self/ns/pid)"; echo "pid=$$"; echo "ppid=$PPID"; echo "uid=$(id -u)";
   echo "outer_fd=${{ZB_OUTER_PIDNS_FD:-}}"; }} > {record}
sh -c 'sleep 60' {marker} &
exit {rc}
"""


def step_command(module):
    text = (REPO / "build.zig").read_text()
    hits = re.findall(r'^\s*"((?:[^"\\]|\\.)*-m unittest -v ' + module + r'\b(?:[^"\\]|\\.)*)",$', text, re.M)
    if len(hits) != 1:
        raise AssertionError(f"{module}: {len(hits)} registered step commands")
    return hits[0].replace('\\"', '"').replace("\\\\", "\\")


def alive_with(marker):
    found = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
        except (OSError, IndexError):
            continue
        if marker.encode() in argv and state != "Z":
            found.append(int(pid))
    return found


class Wrappers(unittest.TestCase):
    def run_step(self, module, rc):
        tmp = Path(tempfile.mkdtemp(prefix="zb-wrap-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        record, marker = tmp / "record", f"zb-wrap-marker-{secrets.token_hex(6)}"
        standin = tmp / "python"
        standin.write_text(STANDIN.format(record=record, marker=marker, rc=rc))
        standin.chmod(stat.S_IRWXU)
        env = {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY")}
        env["ZB_AGENT_HOST_PYTHON"] = str(standin)
        done = subprocess.run(["sh", "-c", step_command(module)], cwd=REPO, env=env, capture_output=True, text=True,
                              timeout=120)
        rows = dict(line.split("=", 1) for line in record.read_text().splitlines()) if record.exists() else {}
        deadline = time.monotonic() + 5
        while alive_with(marker) and time.monotonic() < deadline:
            time.sleep(0.05)
        return done, rows, alive_with(marker)

    def check(self, module, parent_above_one):
        mine = os.readlink("/proc/self/ns/pid")
        for rc in (37, 0):
            with self.subTest(module=module, rc=rc):
                done, rows, left = self.run_step(module, rc)
                self.assertEqual(done.returncode, rc, f"the wrapper did not keep the status: {done.stdout[-300:]}")
                self.assertTrue(rows, "the stand-in never ran")
                self.assertNotEqual(rows.get("ns"), mine, "the stand-in ran in this test's own PID namespace")
                self.assertEqual(rows.get("uid"), str(os.getuid()), "the namespace does not keep our own uid")
                if parent_above_one:
                    self.assertGreater(int(rows.get("ppid", "0")), 1, rows)
                self.assertEqual(left, [], "a process the stand-in left outlived the step")
                yield rows

    def test_the_setup_darwin_steps(self):
        for module in SETUP_DARWIN:
            for _ in self.check(module, parent_above_one=True):
                pass

    def test_test_contract_holds_the_outer_namespace_for_pidns_guard(self):
        for rows in self.check("test_contract", parent_above_one=False):
            self.assertTrue(rows.get("outer_fd", "").isdigit(), rows)
            self.assertEqual(rows.get("ppid"), "1", "pidns_guard wants pid 1 to be the test's parent")

    def test_test_chat_redact_and_test_hook_net(self):
        for module in ("test_chat_redact", "test_hook_net"):
            for _ in self.check(module, parent_above_one=False):
                pass


if __name__ == "__main__":
    unittest.main()
