"""MS6.5 (plan :1619) escape stand-in — like watch_stub.py, but its descendant tries to ESCAPE setup's process
group with setsid() + a double-fork, exactly as a hostile hook would to outlive `kill -9` of the browser.

argv: <browser_pid> <ready_file>
Arms zb_agent_host.parent_watch (real DarwinOps), then launches a detached "hook": the hook forks, the child
calls setsid() (a NEW session + process group, so it is no longer in setup's group), forks AGAIN and the
intermediate exits (so the survivor is not even a session leader and is reparented to launchd). The final
survivor writes "<pid> <pgid>" to <ready_file> and sleeps. setup then sleeps.

Because parent_watch reaps with killpg(setup's pgid), a survivor whose pgid != setup's pgid is NOT reached —
that is the gap MS6.5 pins. The driver confirms the escape (pgid differs) and then requires the survivor to be
dead within 2 s of the browser's SIGKILL; today it is not (RED), and it greens when the reap walks the
descendant TREE (or each hook dies with its own parent) instead of only the leader's group.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "host"))
from zb_agent_host import parent_watch  # noqa: E402

browser_pid = int(sys.argv[1])
ready = sys.argv[2]

if not parent_watch.arm(browser_pid, parent_watch.DarwinOps()):
    sys.exit(3)  # a failed arm kills the group; unreachable in practice

# The escaping "hook": setsid + double-fork, fully detached from setup's process group.
# BOUNDED LIFETIME (RoseCat 7043 #1): the survivor self-exits after ESCAPEE_TTL seconds no matter what, so a
# readiness timeout or an error branch in the driver can never strand an indefinite orphan — the worst case is a
# process that dies on its own within the TTL. The driver also learns the pid from <ready> and kills it; this is
# the belt to that suspenders. The 2 s survival window the driver asserts is far inside the TTL.
ESCAPEE_TTL = 20
SETUP_TTL = 25  # setup is normally killed by parent_watch on the browser's death; bound it too, just in case.

if os.fork() == 0:
    os.setsid()               # new session + process group (pgid = this pid): leaves setup's group
    if os.fork() == 0:        # double-fork: the survivor is not a session leader and reparents to launchd
        tmp = ready + ".esc"
        with open(tmp, "w") as f:
            f.write("%d %d" % (os.getpid(), os.getpgid(0)))
        os.rename(tmp, ready)  # atomic: the driver reads a complete "<pid> <pgid>"
        time.sleep(ESCAPEE_TTL)
        os._exit(0)
    os._exit(0)               # the intermediate exits immediately
# setup (the group leader) stays alive until parent_watch kills it (or the bounded TTL, as a safety net).
time.sleep(SETUP_TTL)
