#!/usr/bin/env python3
"""The MS1b workload that the MS1c gate runs on a Mac stops every browser with SIGTERM only (bd zigBrowser-4pa.73;
SilverRidge 94ebe76b Q1; the session brief forbids SIGKILL on a Mac; tests/e2e/mac_term_teardown.py).

It drives the three real launch paths of that workload against a fake browser (a Python child that records its pid
and process group, and either quits on SIGTERM or ignores it):
  G  m9_reply_channel_test.run_macos_gui_until (m9_render's protocol window, m9_reply_channel, m9_load_fail);
  S  m9_render_test.run_screenshot_capture (the screenshot path, a subprocess.run timeout today);
  A  exec_arch_probe.main (the exec-arch readback).
Each case runs in its own child process with os.kill and os.killpg wrapped to record every signal (they still
deliver it), and must show:
  - the browser ran in its own process group (not the case process's group);
  - no signal other than SIGTERM (or the 0 probe) was sent, so no SIGKILL by os.kill, os.killpg, Popen.kill,
    Popen.send_signal or a subprocess.run timeout;
  - SIGTERM reached the browser's whole group through os.killpg;
  - obey: the browser is gone afterwards;
  - ignore: the browser is LEFT running, one LEAK<TAB><pid><TAB><pgid><TAB>... line names it, and the case process
    exits 1 with FAIL<TAB>mac-teardown-leak.
Cases: G1 G2, S1 S2, A1 A2 (1 = obeys SIGTERM, 2 = ignores it).
It signals real children, so it runs ONLY in a private PID (and network) namespace under a reaping shell; run plainly
it re-runs itself there with unshare, and as anything else it prints FAIL and exits 1 before spawning anything.
Run: python3 tests/e2e/mac_m9_term_only_test.py
"""
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MAC = os.path.join(os.path.dirname(HERE), "mac")
NAME = "mac-m9-term-only-test"
FAKE = """#!/usr/bin/env python3
import os, signal, time
if os.environ.get("ZB_FAKE_MODE") == "ignore":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.environ["ZB_FAKE_INFO"], "w") as f:
    f.write(f"{os.getpid()} {os.getpgid(0)}\\n")
while True:
    time.sleep(0.1)
"""


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().split(") ", 1)[1][0] != "Z"
    except OSError:
        return False


def run_case(name: str) -> int:
    """One case in this process: record every signal, drive the real path, report the browser's fate."""
    sys.path[:0] = [HERE, MAC]
    real_kill, real_killpg = os.kill, os.killpg

    def spy_kill(pid, sig):
        print(f"SIG\tkill\t{pid}\t{int(sig)}", flush=True)
        return real_kill(pid, sig)

    def spy_killpg(pgid, sig):
        print(f"SIG\tkillpg\t{pgid}\t{int(sig)}", flush=True)
        return real_killpg(pgid, sig)

    os.kill, os.killpg = spy_kill, spy_killpg
    work = tempfile.mkdtemp(prefix=f"zb-m9-term-{name}-")
    fake = os.path.join(work, "zigBrowser")
    with open(fake, "w") as f:
        f.write(FAKE)
    os.chmod(fake, 0o755)
    info = os.path.join(work, "info")
    os.environ["ZB_FAKE_MODE"] = "ignore" if name.endswith("2") else "obey"
    os.environ["ZB_FAKE_INFO"] = info
    os.environ["TMPDIR"] = work
    tempfile.tempdir = work
    kind = name[0]
    if kind == "G":
        import m9_reply_channel_test as m
        m.platform.system = lambda: "Darwin"
        m.run_macos_gui_until([fake, "about:blank"], dict(os.environ), 1.5, lambda *_a: False)
    elif kind == "S":
        from pathlib import Path
        import m9_render_test as r
        r.run_screenshot_capture(Path(fake), "about:blank", Path(work) / "shot.png", 1.5)
    else:
        import exec_arch_probe as a
        sys.argv = ["exec_arch_probe.py", "--browser", fake, "--out", os.path.join(work, "arch"), "--timeout", "1.5"]
        a.main()
    bpid = bpgid = -1
    for _ in range(50):
        try:
            with open(info) as f:
                bpid, bpgid = (int(x) for x in f.read().split())
            break
        except (OSError, ValueError):
            time.sleep(0.1)
    deadline = time.monotonic() + 3
    while bpid > 1 and alive(bpid) and time.monotonic() < deadline:
        time.sleep(0.1)
    state = "alive" if bpid > 1 and alive(bpid) else "gone"
    print(f"INFO\t{bpid}\t{bpgid}\t{os.getpgid(0)}\t{state}", flush=True)
    return 0


def judge(name: str, rc: int, out: str) -> list:
    lines = out.splitlines()
    info = [l.split("\t") for l in lines if l.startswith("INFO\t")]
    if len(info) != 1:
        return [f"{name}: no INFO line (exit {rc}): {out[-400:]!r}"]
    _, bpid, bpgid, own, state = info[0]
    sigs = [l.split("\t") for l in lines if l.startswith("SIG\t")]
    probs = []
    if int(bpid) <= 1:
        probs.append("the fake browser never started")
    if bpgid == own:
        probs.append(f"the browser ran in the case's own process group {own}")
    other = sorted({s[3] for s in sigs if s[3] not in ("0", str(int(signal.SIGTERM)))})
    if other:
        probs.append(f"signals other than SIGTERM sent: {other} ({[' '.join(s[1:]) for s in sigs]})")
    if not any(s[1] == "killpg" and s[2] == bpgid and s[3] == str(int(signal.SIGTERM)) for s in sigs):
        probs.append(f"no SIGTERM to the browser's group {bpgid} ({[' '.join(s[1:]) for s in sigs]})")
    leaks = [l.split("\t") for l in lines if l.startswith("LEAK\t")]
    if name.endswith("1"):
        if state != "gone":
            probs.append("the browser that quits on SIGTERM is still running")
        if leaks or rc != 0:
            probs.append(f"a leak or a failed exit ({rc}) for a browser that quit")
    else:
        if state != "alive":
            probs.append("the browser that ignores SIGTERM was not left running")
        if not any(len(l) >= 5 and l[1] == bpid for l in leaks):
            probs.append(f"no LEAK line names pid {bpid}")
        if rc != 1 or f"FAIL\tmac-teardown-leak" not in out:
            probs.append(f"the case did not fail its exit on the leak (exit {rc})")
    return [f"{name}: {p}" for p in probs]


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--case":
        return run_case(sys.argv[2])
    if sys.argv[1:] != ["--inner"]:
        cmd = f"python3 -B {os.path.abspath(__file__)} --inner; exit $?"
        return subprocess.run(["unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--net",
                               "bash", "-c", cmd]).returncode
    if os.getpid() > 50 or os.getpid() == 1:
        print(f"FAIL\t{NAME}\tnot under a reaping init in a private PID namespace (pid {os.getpid()}); nothing was run")
        return 1
    fails = 0
    for name in ("G1", "G2", "S1", "S2", "A1", "A2"):
        # Output goes to a file and the driver waits for the case process, not for EOF: a browser that is left
        # running (the leak cases) inherits the case's descriptors and would hold a pipe open.
        with tempfile.TemporaryFile("w+") as log:
            p = subprocess.Popen([sys.executable, "-B", os.path.abspath(__file__), "--case", name],
                                 stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
            rc = p.wait(timeout=120)
            log.seek(0)
            probs = judge(name, rc, log.read())
        if probs:
            fails += 1
            for msg in probs:
                print(f"FAIL {msg}")
        else:
            print(f"ok   {name}: own process group, SIGTERM only, "
                  + ("the browser is gone" if name.endswith("1") else "the browser is left running with one LEAK"))
    if fails:
        print(f"FAIL\t{NAME}\t{fails} case(s)")
        return 1
    print(f"PASS\t{NAME}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
