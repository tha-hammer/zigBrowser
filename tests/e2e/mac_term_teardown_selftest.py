#!/usr/bin/env python3
"""Selftest of the SIGTERM-only Mac teardown (tests/e2e/mac_term_teardown.py; bd zigBrowser-3ui.7).

It spawns and signals real children, so it runs ONLY inside a private PID namespace, under a shell that is the
namespace's init and reaps orphans as launchd does on a Mac (`unshare --user --map-root-user --pid --fork --mount-proc
bash -c 'python3 ...'`, as tests/mac/mac_gate_callers_selftest.sh starts it); anywhere else, or as pid 1 itself, it
prints FAIL and exits 1 before spawning anything. Every os.killpg call is recorded; a non-zero signal other than
SIGTERM fails the test. Children left running die with the namespace.
  T1 a child that quits on SIGTERM: reaped, SIGTERM only, no leak;
  T2 a child that ignores SIGTERM: left running, one LEAK, no other signal;
  T3 an exited and reaped child with no group left: no signal at all;
  T4 pids 1, 0, True, "12", None: refused, no signal;
  T5 an exited, reaped leader whose group child quits on SIGTERM (mac_ms2a_teardown_test's case): the child is
     reached and gone, SIGTERM only, no leak;
  T6 the same with a child that ignores SIGTERM: left running, one LEAK;
  T7 a test process whose teardown leaked but whose main returns 0 exits 1 and prints FAIL\tmac-teardown-leak, and
     at the leak one LEAK<TAB>pid<TAB>pgid<TAB>start<TAB>command line naming exactly the leaked child;
  T8 run_term_only past its timeout raises TimeoutExpired and the child is gone, SIGTERM only;
  T9 mac_ms2a_routed_test.stop_browser_macos (the ms2a/ms2b/ms2c helper) stops a child with SIGTERM only.
"""
import os
import signal
import subprocess
import sys
import time

if os.getpid() > 50 or os.getpid() == 1:
    print(f"FAIL\tmac-term-teardown-selftest\tnot under a reaping init in a private PID namespace (pid {os.getpid()}); "
          "nothing was run")
    sys.exit(1)

import mac_term_teardown as t  # noqa: E402

failures: list = []
sent: list = []
_real_killpg = os.killpg


def _spy(pgid, sig):
    if sig != 0:
        sent.append(sig)
    return _real_killpg(pgid, sig)


os.killpg = _spy
PY = sys.executable
IGNORE_TERM = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # a zombie still answers kill(pid, 0); read its state
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().split(") ", 1)[1][0] != "Z"
    except OSError:
        return False


def expect(name: str, cond: bool, detail) -> None:
    if not cond:
        failures.append(f"{name}: {detail}")


def leaks() -> int:
    return len(t.leak_failures())


def leader_with_child(child_src: str):
    """A group leader that starts a child in its group, prints the child's pid, and exits at once (reaped here)."""
    src = f"import subprocess,sys; c=subprocess.Popen([sys.executable,'-c',{child_src!r}]); print(c.pid, flush=True)"
    leader = subprocess.Popen([PY, "-c", src], stdout=subprocess.PIPE, text=True, start_new_session=True)
    child = int(leader.stdout.readline())
    leader.stdout.close()
    leader.wait()
    time.sleep(0.3)
    return leader, child


def main() -> int:
    sent.clear(); n0 = leaks()
    p = subprocess.Popen([PY, "-c", "import time; time.sleep(60)"], start_new_session=True)
    time.sleep(0.3); t.stop_browser_term_only(p, grace_s=3)
    expect("T1", p.returncode == -signal.SIGTERM and sent == [signal.SIGTERM] and leaks() == n0, (p.returncode, sent))

    sent.clear(); n0 = leaks()
    q = subprocess.Popen([PY, "-c", IGNORE_TERM], start_new_session=True)
    time.sleep(0.5); t.stop_browser_term_only(q, grace_s=1)
    expect("T2", alive(q.pid) and sent == [signal.SIGTERM] and leaks() == n0 + 1, (alive(q.pid), sent, leaks() - n0))

    sent.clear(); n0 = leaks()
    r = subprocess.Popen(["true"], start_new_session=True); r.wait()
    t.stop_browser_term_only(r)
    expect("T3", sent == [] and leaks() == n0, (sent, leaks() - n0))

    class Fake:
        def __init__(self, pid):
            self.pid, self.returncode = pid, None

    sent.clear(); n0 = leaks()
    for bad in (1, 0, True, "12", None):
        t.stop_browser_term_only(Fake(bad))
    expect("T4", sent == [] and leaks() == n0 + 5, (sent, leaks() - n0))

    sent.clear(); n0 = leaks()
    leader, child = leader_with_child("import time; time.sleep(60)")
    t.stop_browser_term_only(leader, grace_s=3)
    expect("T5", not alive(child) and sent == [signal.SIGTERM] and leaks() == n0, (alive(child), sent, leaks() - n0))

    sent.clear(); n0 = leaks()
    leader, child = leader_with_child(IGNORE_TERM)
    t.stop_browser_term_only(leader, grace_s=1)
    expect("T6", alive(child) and sent == [signal.SIGTERM] and leaks() == n0 + 1, (alive(child), sent, leaks() - n0))

    here = os.path.dirname(os.path.abspath(__file__))
    leak_src = ("import subprocess,sys,time; import mac_term_teardown as t;"
                f"q=subprocess.Popen([sys.executable,'-c',{IGNORE_TERM!r}], start_new_session=True); time.sleep(0.5);"
                "print(f'CHILD\\t{q.pid}', flush=True); t.stop_browser_term_only(q, grace_s=0.5);"
                "print('PASS\\tpretend', flush=True); sys.exit(0)")
    res = subprocess.run([PY, "-c", leak_src], cwd=here, capture_output=True, text=True,
                         env={**os.environ, "PYTHONPATH": here})
    child = next((l.split("\t")[1] for l in res.stdout.splitlines() if l.startswith("CHILD\t")), "?")
    ident = [l.split("\t") for l in res.stdout.splitlines() if l.startswith("LEAK\t")]
    expect("T7", res.returncode == 1 and "FAIL\tmac-teardown-leak\t1" in res.stdout and len(ident) == 1
           and ident[0][1:3] == [child, child] and "signal.SIG_IGN" in ident[0][4], (res.returncode, res.stdout))

    sent.clear()
    try:
        t.run_term_only(["sleep", "30"], 0.3)
        expect("T8", False, "no TimeoutExpired")
    except subprocess.TimeoutExpired:
        expect("T8", sent == [signal.SIGTERM], sent)

    sent.clear(); n0 = leaks()
    import mac_ms2a_routed_test as routed  # noqa: E402
    s = subprocess.Popen([PY, "-c", "import time; time.sleep(60)"], start_new_session=True)
    time.sleep(0.3); routed.stop_browser_macos(s)
    expect("T9", s.returncode == -signal.SIGTERM and sent == [signal.SIGTERM] and leaks() == n0, (s.returncode, sent))

    expected_leaks = 1 + 5 + 1  # T2, T4, T6
    if failures or leaks() != expected_leaks:
        print("FAIL\tmac-term-teardown-selftest")
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        if leaks() != expected_leaks:
            print(f"  leaks recorded {leaks()}, want {expected_leaks}", file=sys.stderr)
        sys.stdout.flush()
        os._exit(1)
    print("PASS\tmac-term-teardown-selftest\t9 cases", flush=True)
    os._exit(0)  # the expected leaks of T2/T4/T6 would otherwise turn this exit into 1 (that is T7's behavior)


if __name__ == "__main__":
    main()
