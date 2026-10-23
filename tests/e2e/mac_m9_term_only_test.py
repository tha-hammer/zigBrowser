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
  - the only signal sent (not 0) is exactly one killpg(<browser pgid>, SIGTERM): no direct kill, no other process or
    group, no second TERM; signal 0 only probes the browser's pid or group;
  - obey: the browser is gone and reaped afterwards, with no LEAK and exit 0;
  - ignore: the browser is LEFT running, exactly one LEAK<TAB><pid><TAB><pgid><TAB><start><TAB><command> record
    names it, with its pid, its pgid and the start time and command ps shows for it, and the case process exits 1
    with exactly one FAIL<TAB>mac-teardown-leak.
J (first) checks the judge itself: a safe transcript of each kind passes, and each unsafe variant is refused: an
extra direct TERM, a TERM to the wrong group, a second TERM, a direct TERM instead, a SIGKILL, a probe of another
process, a duplicate LEAK, a LEAK with the wrong pgid, start or command, no LEAK, two leak FAIL lines, exit 0 after
a leak, an unread identity, a LEAK for a browser that quit, and a browser that quit but is a zombie.
Cases: J, then G1 G2, S1 S2, A1 A2 (1 = obeys SIGTERM, 2 = ignores it).
It signals real children, so it runs ONLY in a private PID (and network) namespace under a reaping shell; run plainly
it re-runs itself there with unshare, and as anything else it prints FAIL and exits 1 before spawning anything.
Run: python3 tests/e2e/mac_m9_term_only_test.py
"""
import os
import re
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


def ps_identity(pid: int) -> tuple:
    """(start, command) of pid, read the way mac_term_teardown._group_identity reads it (ps lstart and command)."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,lstart=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        f = line.split(None, 7)
        if len(f) == 8 and f[0] == str(pid):
            return " ".join(f[2:7]), f[7]
    return "-", "-"


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
    start, command = ps_identity(bpid) if bpid > 1 else ("-", "-")
    deadline = time.monotonic() + 3
    while bpid > 1 and os.path.exists(f"/proc/{bpid}") and time.monotonic() < deadline:
        time.sleep(0.1)  # until it is gone and reaped (a browser left running stays)
    state = "alive" if bpid > 1 and alive(bpid) else ("zombie" if bpid > 1 and os.path.exists(f"/proc/{bpid}") else "gone")
    print(f"INFO\t{bpid}\t{bpgid}\t{os.getpgid(0)}\t{state}\t{start}\t{command}", flush=True)
    return 0


LSTART = re.compile(r"^[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}$")


def judge(name: str, rc: int, out: str) -> list:
    """Problems with one case's transcript; an empty list is the only pass."""
    lines = out.splitlines()
    info = [l.split("\t") for l in lines if l.startswith("INFO\t")]
    if len(info) != 1 or len(info[0]) != 7:
        return [f"{name}: no single INFO line (exit {rc}): {out[-400:]!r}"]
    _, bpid, bpgid, own, state, start, command = info[0]
    sigs = [l.split("\t") for l in lines if l.startswith("SIG\t")]
    probs = []
    if not bpid.isdigit() or int(bpid) <= 1 or not bpgid.isdigit():
        return [f"{name}: the fake browser never started"]
    if bpgid == own:
        probs.append(f"the browser ran in the case's own process group {own}")
    if any(len(s) != 4 for s in sigs):
        probs.append(f"a malformed SIG line: {sigs}")
    # The one allowed send: SIGTERM to the browser's whole group, exactly once. Signal 0 only probes the browser.
    sends = [s[1:] for s in sigs if len(s) == 4 and s[3] != "0"]
    if sends != [["killpg", bpgid, str(int(signal.SIGTERM))]]:
        probs.append(f"the sends were {sends}, not exactly one killpg({bpgid}, SIGTERM)")
    probes = [s[1:] for s in sigs if len(s) == 4 and s[3] == "0"]
    stray = [p for p in probes if p not in (["kill", bpid, "0"], ["killpg", bpgid, "0"])]
    if stray:
        probs.append(f"liveness probes of another process or group: {stray}")
    leaks = [l.split("\t") for l in lines if l.startswith("LEAK\t")]
    fails = [l for l in lines if l.startswith("FAIL\tmac-teardown-leak")]
    if name.endswith("1"):
        if state != "gone":
            probs.append(f"the browser that quits on SIGTERM is {state}, not gone and reaped")
        if leaks or fails or rc != 0:
            probs.append(f"{len(leaks)} LEAK and {len(fails)} leak FAIL line(s), exit {rc}, for a browser that quit")
    else:
        if state != "alive":
            probs.append(f"the browser that ignores SIGTERM is {state}, not left running")
        if not LSTART.match(start) or not command or command == "-":
            probs.append(f"the browser's own identity was not read (start {start!r}, command {command!r})")
        want = ["LEAK", bpid, bpgid, start, command]
        if len(leaks) != 1 or leaks[0] != want:
            probs.append(f"the LEAK records were {leaks}, not exactly one {want}")
        if rc != 1 or len(fails) != 1:
            probs.append(f"exit {rc} with {len(fails)} FAIL<TAB>mac-teardown-leak line(s), not exit 1 with one")
    return [f"{name}: {p}" for p in probs]


def judge_controls() -> list:
    """The oracle itself: one good transcript per kind passes, and every unsafe variant of it is refused."""
    start, cmd = "Thu Oct 23 10:00:00 2026", "python3 /tmp/w/zigBrowser about:blank"
    info_i = f"INFO\t40\t39\t1\talive\t{start}\t{cmd}"
    term, probe = "SIG\tkillpg\t39\t15", "SIG\tkillpg\t39\t0"
    leak, fail = f"LEAK\t40\t39\t{start}\t{cmd}", "FAIL\tmac-teardown-leak\t1"
    good_i = [probe, term, probe, leak, info_i, fail]
    good_o = [term, "SIG\tkill\t40\t0", "INFO\t40\t39\t1\tgone\t-\t-"]
    probs = []
    for label, text, rc in (("good ignore", good_i, 1), ("good obey", good_o, 0)):
        got = judge(label + "2" if "ignore" in label else label + "1", rc, "\n".join(text))
        if got:
            probs.append(f"J: the {label} transcript is refused: {got}")
    variants = {
        "an extra direct TERM": ([probe, term, "SIG\tkill\t40\t15", leak, info_i, fail], 1),
        "a TERM to the wrong group": ([probe, "SIG\tkillpg\t38\t15", leak, info_i, fail], 1),
        "a second TERM": ([probe, term, term, leak, info_i, fail], 1),
        "a direct TERM instead": ([probe, "SIG\tkill\t40\t15", leak, info_i, fail], 1),
        "a SIGKILL": ([probe, term, "SIG\tkillpg\t39\t9", leak, info_i, fail], 1),
        "a probe of another process": ([probe, term, "SIG\tkill\t41\t0", leak, info_i, fail], 1),
        "a duplicate LEAK": ([probe, term, leak, leak, info_i, fail], 1),
        "a LEAK with the wrong pgid": ([probe, term, f"LEAK\t40\t38\t{start}\t{cmd}", info_i, fail], 1),
        "a LEAK with the wrong start": ([probe, term, f"LEAK\t40\t39\tThu Oct 23 10:00:01 2026\t{cmd}", info_i, fail], 1),
        "a LEAK with the wrong command": ([probe, term, f"LEAK\t40\t39\t{start}\tpython3 other", info_i, fail], 1),
        "no LEAK": ([probe, term, info_i, fail], 1),
        "two leak FAIL lines": ([probe, term, leak, info_i, fail, fail], 1),
        "exit 0 after a leak": ([probe, term, leak, info_i, fail], 0),
        "an unread identity": ([probe, term, "LEAK\t40\t39\t-\t-", "INFO\t40\t39\t1\talive\t-\t-", fail], 1),
    }
    for label, (text, rc) in variants.items():
        if not judge("J2", rc, "\n".join(text)):
            probs.append(f"J: {label} is accepted")
    for label, text in (("a LEAK for a browser that quit", good_o + [leak]),
                        ("a browser that quit but is a zombie", [term, "INFO\t40\t39\t1\tzombie\t-\t-"])):
        if not judge("J1", 0, "\n".join(text)):
            probs.append(f"J: {label} is accepted")
    return probs


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
    controls = judge_controls()
    for msg in controls:
        print(f"FAIL {msg}")
    if controls:
        fails += 1
    else:
        print("ok   J: the judge passes 2 safe transcripts and refuses all 16 unsafe variants")
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
