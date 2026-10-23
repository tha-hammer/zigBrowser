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
  - the browser leads its own process group: pgid == pid, a decimal > 1 (never group 1), not the case's group;
  - the only signal sent (not 0) is exactly one killpg(<browser pid>, SIGTERM): no SIGKILL by os.kill, os.killpg,
    Popen.kill, Popen.send_signal or a subprocess.run timeout, no direct kill, no other process or group, no second
    TERM; signal 0 only probes the browser's pid or group;
  - obey: the browser is gone and reaped afterwards, with no LEAK and exit 0;
  - ignore: the browser is LEFT running, exactly one LEAK<TAB><pid><TAB><pgid><TAB><start><TAB><command> record
    names it, with its pid as pid and pgid and the start time and command ps shows for it, and the case process
    exits 1 with exactly one FAIL<TAB>mac-teardown-leak.
R (first) drives the namespace guard: a case run whose launcher record is missing, or names this PID or network
namespace as the host's, is refused (exit 1, one refusal line) before it creates the fake browser or sends a signal.
J checks the judge itself: a safe transcript of each kind passes, and each unsafe variant is refused: an extra
direct TERM, a TERM to the wrong group, a second TERM, a direct TERM instead, a SIGKILL, a probe of another process,
a duplicate LEAK, a LEAK with the wrong pgid, start or command, no LEAK, two leak FAIL lines, exit 0 after a leak, an
unread identity, a browser group that is not its pid and group 1 (each as a consistent transcript, and field-isolated
with only the recorded pgid wrong), group 1 for a browser that quit, a LEAK for a browser that quit, and a browser
that quit but is a zombie.
Rows: R, J, then G1 G2, S1 S2, A1 A2 (1 = obeys SIGTERM, 2 = ignores it).
It signals real children, so every case runs ONLY behind namespace_problem(): the top-level launcher records the
host's PID and network namespace inodes, re-runs this file under unshare (private user, PID with a reaping shell,
mount for /proc, and network namespaces), and each --inner or --case process verifies that both of its namespaces
differ from the recorded ones and that its pid is small and not 1, before anything else. A --case or --inner call
from anywhere else prints FAIL and exits 1 before it creates anything or sends any signal.
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


def namespace_problem():
    """None only inside the private PID and network namespaces this file's own launcher made; else the reason.
    The launcher records the host's pid and net namespace inodes in the environment before unshare; here both of this
    process's namespaces must differ from them, and its pid must be a small one of the new PID namespace (not 1)."""
    try:
        host_pid = int(os.environ["ZB_M9_TERM_HOST_PIDNS"])
        host_net = int(os.environ["ZB_M9_TERM_HOST_NETNS"])
        own_pid = os.stat("/proc/self/ns/pid").st_ino
        own_net = os.stat("/proc/self/ns/net").st_ino
    except (KeyError, ValueError, OSError) as exc:
        return f"the launcher's namespace record is missing or unreadable ({exc!r})"
    if own_pid == host_pid:
        return f"not in a private PID namespace (pid ns {own_pid} is the host's)"
    if own_net == host_net:
        return f"not in a private network namespace (net ns {own_net} is the host's)"
    if os.getpid() > 50 or os.getpid() == 1:
        return f"not under a reaping init in the private PID namespace (pid {os.getpid()})"
    return None


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
    """One case in this process: record every signal, drive the real path, report the browser's fate. It runs only
    behind namespace_problem() (checked by main() before it gets here, and again here before anything is created)."""
    why = namespace_problem()
    if why:
        print(f"FAIL\t{NAME}\tcase {name} refused: {why}; nothing was run", flush=True)
        return 1
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
    if not bpid.isdigit() or int(bpid) <= 1:
        return [f"{name}: the fake browser never started"]
    # The browser leads its own group: pgid == pid, a decimal > 1 (never group 1, init's), not the case's group.
    if not bpgid.isdigit() or int(bpgid) <= 1 or bpgid != bpid:
        probs.append(f"the browser's process group {bpgid!r} is not its own pid {bpid}")
    if bpgid == own:
        probs.append(f"the browser ran in the case's own process group {own}")
    if any(len(s) != 4 for s in sigs):
        probs.append(f"a malformed SIG line: {sigs}")
    # The one allowed send: SIGTERM to the browser's whole group, exactly once. Signal 0 only probes the browser.
    sends = [s[1:] for s in sigs if len(s) == 4 and s[3] != "0"]
    if sends != [["killpg", bpid, str(int(signal.SIGTERM))]]:
        probs.append(f"the sends were {sends}, not exactly one killpg({bpid}, SIGTERM)")
    probes = [s[1:] for s in sigs if len(s) == 4 and s[3] == "0"]
    stray = [p for p in probes if p not in (["kill", bpid, "0"], ["killpg", bpid, "0"])]
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
        want = ["LEAK", bpid, bpid, start, command]
        if len(leaks) != 1 or leaks[0] != want:
            probs.append(f"the LEAK records were {leaks}, not exactly one {want}")
        if rc != 1 or len(fails) != 1:
            probs.append(f"exit {rc} with {len(fails)} FAIL<TAB>mac-teardown-leak line(s), not exit 1 with one")
    return [f"{name}: {p}" for p in probs]


def judge_controls() -> list:
    """The oracle itself: one good transcript per kind passes, and every unsafe variant of it is refused."""
    start, cmd = "Thu Oct 23 10:00:00 2026", "python3 /tmp/w/zigBrowser about:blank"
    info_i = f"INFO\t40\t40\t1\talive\t{start}\t{cmd}"
    term, probe = "SIG\tkillpg\t40\t15", "SIG\tkillpg\t40\t0"
    leak, fail = f"LEAK\t40\t40\t{start}\t{cmd}", "FAIL\tmac-teardown-leak\t1"
    good_i = [probe, term, probe, leak, info_i, fail]
    good_o = [term, "SIG\tkill\t40\t0", "INFO\t40\t40\t1\tgone\t-\t-"]
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
        "a SIGKILL": ([probe, term, "SIG\tkillpg\t40\t9", leak, info_i, fail], 1),
        "a probe of another process": ([probe, term, "SIG\tkill\t41\t0", leak, info_i, fail], 1),
        "a duplicate LEAK": ([probe, term, leak, leak, info_i, fail], 1),
        "a LEAK with the wrong pgid": ([probe, term, f"LEAK\t40\t38\t{start}\t{cmd}", info_i, fail], 1),
        "a LEAK with the wrong start": ([probe, term, f"LEAK\t40\t40\tThu Oct 23 10:00:01 2026\t{cmd}", info_i, fail], 1),
        "a LEAK with the wrong command": ([probe, term, f"LEAK\t40\t40\t{start}\tpython3 other", info_i, fail], 1),
        "no LEAK": ([probe, term, info_i, fail], 1),
        "two leak FAIL lines": ([probe, term, leak, info_i, fail, fail], 1),
        "exit 0 after a leak": ([probe, term, leak, info_i, fail], 0),
        "an unread identity": ([probe, term, "LEAK\t40\t40\t-\t-", "INFO\t40\t40\t1\talive\t-\t-", fail], 1),
        # The group itself, each transcript consistent with it, so only the pgid rule can refuse it:
        "a browser group that is not its pid": (["SIG\tkillpg\t39\t0", "SIG\tkillpg\t39\t15", f"LEAK\t40\t39\t{start}\t{cmd}",
                                                f"INFO\t40\t39\t1\talive\t{start}\t{cmd}", fail], 1),
        "group 1": (["SIG\tkillpg\t1\t0", "SIG\tkillpg\t1\t15", f"LEAK\t40\t1\t{start}\t{cmd}",
                     f"INFO\t40\t1\t7\talive\t{start}\t{cmd}", fail], 1),
        # Field-isolated: everything names the pid 40, and only the browser's recorded pgid is wrong.
        "only the recorded pgid differs from the pid": ([probe, term, probe, leak, f"INFO\t40\t39\t1\talive\t{start}\t{cmd}", fail], 1),
        "only the recorded pgid is 1": ([probe, term, probe, leak, f"INFO\t40\t1\t7\talive\t{start}\t{cmd}", fail], 1),
    }
    for label, (text, rc) in variants.items():
        if not judge("J2", rc, "\n".join(text)):
            probs.append(f"J: {label} is accepted")
    for label, text in (("a LEAK for a browser that quit", good_o + [leak]),
                        ("a browser that quit but is a zombie", [term, "INFO\t40\t40\t1\tzombie\t-\t-"]),
                        ("an obeying browser in group 1", ["SIG\tkillpg\t1\t15", "INFO\t40\t1\t7\tgone\t-\t-"])):
        if not judge("J1", 0, "\n".join(text)):
            probs.append(f"J: {label} is accepted")
    return probs


def refusal_controls() -> list:
    """R: a case run that is not behind this file's own private namespaces is refused before it creates the fake
    browser or sends a signal. Driven here, inside the namespaces, by spoiling the launcher's record three ways."""
    probs = []
    own_pid = str(os.stat("/proc/self/ns/pid").st_ino)
    own_net = str(os.stat("/proc/self/ns/net").st_ino)
    spoils = {"no namespace record": {"ZB_M9_TERM_HOST_PIDNS": None, "ZB_M9_TERM_HOST_NETNS": None},
              "the PID namespace recorded as the host's": {"ZB_M9_TERM_HOST_PIDNS": own_pid},
              "the network namespace recorded as the host's": {"ZB_M9_TERM_HOST_NETNS": own_net}}
    for label, change in spoils.items():
        env = dict(os.environ)
        for k, v in change.items():
            if v is None:
                env.pop(k, None)
            else:
                env[k] = v
        with tempfile.TemporaryDirectory() as tmp:
            env["TMPDIR"] = tmp
            p = subprocess.run([sys.executable, "-B", os.path.abspath(__file__), "--case", "G1"], env=env,
                               capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
            made = os.listdir(tmp)
        out = p.stdout + p.stderr
        refused = [l for l in out.splitlines() if l.startswith(f"FAIL\t{NAME}\tcase G1 refused: ")]
        if p.returncode != 1 or len(refused) != 1 or "SIG\t" in out or "INFO\t" in out or made:
            probs.append(f"R: {label}: exit {p.returncode}, created {made}, output {out[-300:]!r}")
    return probs


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["--case"]:
        why = namespace_problem()   # before anything else: no fake browser, no signal, outside the namespaces
        if len(args) != 2 or why:
            label = args[1] if len(args) == 2 else repr(args[1:])
            print(f"FAIL\t{NAME}\tcase {label} refused: {why or 'bad arguments'}; nothing was run", flush=True)
            return 1
        return run_case(args[1])
    if not args:   # the launcher: record the host's namespaces, then re-run inside fresh private ones
        env = dict(os.environ, ZB_M9_TERM_HOST_PIDNS=str(os.stat("/proc/self/ns/pid").st_ino),
                   ZB_M9_TERM_HOST_NETNS=str(os.stat("/proc/self/ns/net").st_ino))
        cmd = f"python3 -B {os.path.abspath(__file__)} --inner; exit $?"
        return subprocess.run(["unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--net",
                               "bash", "-c", cmd], env=env).returncode
    why = namespace_problem()
    if args != ["--inner"] or why:
        print(f"FAIL\t{NAME}\t{why or 'bad arguments'}; nothing was run")
        return 1
    fails = 0
    for row, probs, good in (("R", refusal_controls(), "a case outside this file's private namespaces is refused, "
                              "nothing created, no signal (3 controls)"),
                             ("J", judge_controls(), "the judge passes 2 safe transcripts and refuses all 21 unsafe "
                              "variants")):
        for msg in probs:
            print(f"FAIL {msg}")
        if probs:
            fails += 1
        else:
            print(f"ok   {row}: {good}")
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
            print(f"ok   {name}: its own process group (pgid == pid), one killpg SIGTERM, "
                  + ("the browser is gone" if name.endswith("1") else "the browser is left running with one LEAK"))
    if fails:
        print(f"FAIL\t{NAME}\t{fails} row(s)")
        return 1
    print(f"PASS\t{NAME}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
