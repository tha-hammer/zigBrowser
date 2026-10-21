"""Both-Mac half of the R1 environment check (BlueBeaver 6977): drives zb_agent_host.proc_darwin's REAL libproc and
sysctl KERN_PROCARGS2 calls against our own children. Run by tests/mac/ms5_r1_env_gate.sh, which copies
proc_darwin.py next to this file and passes: <plain sleeper> <hardened sleeper> <non-descendant pid>.

Cases:
 1. a plain (ad-hoc signed) child: descendants_running finds exactly it; environ_of gives its exact argv and an
    environment holding the marker and the canary entries;
 2. the same for a child signed with the hardened runtime (the real CLI is hardened);
 3. a grandchild under /bin/sh is found by the walk, and the shell is not (another path);
 4. a process running the same binary that is not our descendant is never listed;
 5. a reaped child's pid: environ_of raises OSError (never an empty, "clean" environment).
Also printed, not asserted (it differs by OS version): whether /bin/sleep's environment is visible."""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    import proc_darwin
except ImportError:
    print("FAIL\tms5-r1-env\tagent/host/zb_agent_host/proc_darwin.py is missing (6977)")
    sys.exit(1)

MARK = b"ZB_R1_MARK=zb-r1-env-marker-6977"
CANARY = b"ANTHROPIC_BASE_URL=http://127.0.0.1:9"
ENV = {"ZB_R1_MARK": "zb-r1-env-marker-6977", "ANTHROPIC_BASE_URL": "http://127.0.0.1:9", "PATH": "/usr/bin:/bin"}
failures = []


def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        failures.append(what)


def started(argv):
    child = subprocess.Popen(argv, env=ENV)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and proc_darwin.path(child.pid) != os.path.realpath(argv[0]):
        time.sleep(0.02)
    return child


def stop(child):
    child.kill()
    child.wait()


def direct_child(exe, label):
    exe = os.path.realpath(exe)
    child = started([exe, "30"])
    try:
        found = proc_darwin.descendants_running(exe, os.getpid())
        check(found == [child.pid], f"{label}: the walk finds exactly the child ({found} vs {child.pid})")
        raw, argv, env = proc_darwin.environ_of(child.pid)
        check(argv == [exe.encode(), b"30"], f"{label}: argv is exact ({argv})")
        check(MARK in env and CANARY in env, f"{label}: the environment holds the marker and the canary entries")
    finally:
        stop(child)


def grandchild(exe):
    exe = os.path.realpath(exe)
    shell = subprocess.Popen(["/bin/sh", "-c", '"$0" 30; :', exe], env=ENV)
    try:
        deadline = time.monotonic() + 5
        found = []
        while time.monotonic() < deadline and not found:
            found = proc_darwin.descendants_running(exe, os.getpid())
            time.sleep(0.02)
        check(len(found) == 1 and found[0] != shell.pid, f"grandchild: the walk finds the sleeper under sh ({found})")
        if found:
            check(MARK in proc_darwin.environ_of(found[0])[2], "grandchild: its environment is readable")
        check(proc_darwin.descendants_running("/bin/sh", os.getpid()) in ([shell.pid], []),
              "grandchild: the shell is listed only under its own path")
    finally:
        for pid in proc_darwin.descendants_running(exe, os.getpid()):
            os.kill(pid, 9)
        stop(shell)


def not_a_descendant(exe, other_pid):
    exe = os.path.realpath(exe)
    check(proc_darwin.path(other_pid) == exe, f"non-descendant: pid {other_pid} runs the same binary")
    check(other_pid not in proc_darwin.descendants_running(exe, os.getpid()), "non-descendant: never listed")


def reaped(exe):
    child = started([os.path.realpath(exe), "30"])
    stop(child)
    try:
        proc_darwin.environ_of(child.pid)
    except OSError:
        check(True, "reaped: environ_of raises OSError")
    else:
        check(False, "reaped: environ_of raises OSError (it returned an environment)")


def platform_binary_note():
    child = subprocess.Popen(["/bin/sleep", "30"], env=ENV)
    time.sleep(0.3)
    try:
        _, _, env = proc_darwin.environ_of(child.pid)
        print(f"  note /bin/sleep environment visible: {MARK in env} ({len(env)} entries)")
    except OSError as exc:
        print(f"  note /bin/sleep environment unreadable: {exc}")
    finally:
        stop(child)


def main():
    plain, hardened, other = sys.argv[1], sys.argv[2], int(sys.argv[3])
    direct_child(plain, "plain")
    direct_child(hardened, "hardened")
    grandchild(plain)
    not_a_descendant(plain, other)
    reaped(plain)
    platform_binary_note()
    if failures:
        print(f"FAIL\tms5-r1-env\t{len(failures)} failure(s)")
        return 1
    print("PASS\tms5-r1-env\t5 cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
