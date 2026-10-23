#!/usr/bin/env python3
"""MS2a RED (unregistered) — stop_browser_macos reaps a surviving group child after the leader exits.

RoseCat (f8a816a BLOCKER-for-tests / dd0b456 / 6206): the teardown must kill surviving process-group
children even when the session leader has already exited. This is a deterministic, browser-free unit
test of stop_browser_macos: a leader (its own session/group leader via start_new_session) spawns a
long-lived child into its group, prints the child's pid, then exits immediately. The child survives in
the group. stop_browser_macos(leader) must then reap that exact child.

Mutant proof: the pre-fix helper early-returned on `proc.poll() is not None` (leader already exited) and
left the child alive — this test reds against that mutant.
"""
import argparse
import os
import signal
import subprocess
import sys
import time

from mac_ms2a_routed_test import stop_browser_macos  # noqa: E402


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, not ours to signal — still "alive"


# Leader: spawn a long-lived child in our own (new) process group, announce it, then exit at once.
LEADER_SRC = (
    "import subprocess,sys;"
    "c=subprocess.Popen(['sleep','300']);"
    "sys.stdout.write(str(c.pid)+'\\n');sys.stdout.flush()"
)


def main() -> int:
    ap = argparse.ArgumentParser()  # accept the gate harness's flags; this test needs no browser
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    ap.parse_args()
    leader = subprocess.Popen(
        [sys.executable, "-c", LEADER_SRC],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        start_new_session=True,  # leader is its own group leader; the child inherits the group
    )
    child_pid = int(leader.stdout.readline().strip())
    leader.wait()  # leader exits; the child is now an orphan surviving in the group

    failures: list[str] = []
    # Give the orphaned child a moment; it must still be alive before teardown (else the test is vacuous).
    time.sleep(0.2)
    if not _alive(child_pid):
        failures.append("precondition failed: the group child did not outlive the leader")
    else:
        stop_browser_macos(leader)  # leader already exited — must STILL reap the surviving child
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and _alive(child_pid):
            time.sleep(0.05)
        if _alive(child_pid):
            failures.append(f"group child {child_pid} survived stop_browser_macos (exited-leader leak)")
            try:
                os.kill(child_pid, signal.SIGTERM)  # don't leak it ourselves (never SIGKILL on a Mac)
            except OSError:
                pass

    if failures:
        print("FAIL\tms2a-teardown-reap")
        for f in failures:
            eprint(f"  {f}")
        return 1
    print("PASS\tms2a-teardown-reap")
    return 0


if __name__ == "__main__":
    sys.exit(main())
