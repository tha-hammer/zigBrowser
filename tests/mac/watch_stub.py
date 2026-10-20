"""Stand-in for setup.py's Darwin start (macOS plan rev 14 item 5), driven by tests/mac/spawn_group_test.c.

argv: <browser_pid> <ready_file> [barrier_file]
Arms zb_agent_host.parent_watch with the real DarwinOps, then starts a grandchild (`sleep 300`, in the same
process group, as setup's own children would be) and sleeps. With a barrier file, the watch waits between
step 1 and step 2 until that file exists (the check-to-register window the plan's e2e barrier targets).
Writes the grandchild's pid to <ready_file> once armed (or "barrier" once it is waiting at the barrier).
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "host"))
from zb_agent_host import parent_watch  # noqa: E402

browser_pid = int(sys.argv[1])
ready = sys.argv[2]
barrier = sys.argv[3] if len(sys.argv) > 3 else None


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.rename(tmp, path)


class BarrierOps(parent_watch.DarwinOps):
    def register(self, pid):
        if barrier is not None:
            write(ready, "barrier")
            while not os.path.exists(barrier):
                time.sleep(0.01)
        return super().register(pid)


if not parent_watch.arm(browser_pid, BarrierOps()):
    sys.exit(3)  # unreachable in practice: a failed arm kills the group
child = subprocess.Popen(["/bin/sleep", "300"])
write(ready, str(child.pid))
time.sleep(300)
