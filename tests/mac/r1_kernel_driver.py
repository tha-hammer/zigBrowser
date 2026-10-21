"""Both-Mac KERNEL-PROPERTIES red for R1 under Seatbelt (RoseCat 7019 item 2, 7041 #3, 7050; BlueBeaver 7021, 7051).
Scope: the kernel properties the census design relies on. The production chain (real setup.probe_r1 -> route_probe
-> wrapper -> CLI) needs the staged SDK runtime and is a required case of the armed MS5 e2e (7051), not this gate.

This driver plays SETUP, outside any sandbox. It binds the R1 listener and a decoy listener on 127.0.0.1, then runs
an inner script (the probe's position) under the REAL setup profile, sandbox_macos.setup_sandbox(...,
loopback_port=<R1 port>). The inner starts a CLI stand-in (canary in its environment) and a sibling, and reports.
Required, together:
 1. inside: a connect to the R1 port succeeds; a connect to the decoy port fails with the Seatbelt denial errno;
 2. inside: KERN_PROCARGS2 and proc_pidpath of the sibling and of the CLI stand-in fail with the Seatbelt denial
    errno while both targets are alive;
 3. control (sacrificial-canary rule): the SAME inner, run WITHOUT the profile, gets all four introspection reads
    and the decoy connect to succeed;
 4. outside: setup's census proc_darwin.cli_env_clean finds the CLI stand-in and its canary (True); in a second run
    with a token planted in the stand-in's environment, whose own positives must hold first, it is False.
Process ownership: every inner runs in its own process group, every read has a local monotonic deadline, and the
whole group is SIGKILLed and reaped on every path; a live-silent inner is a bounded failure with no survivor (the
harness self-test). Every /tmp/zb-r1k-* scratch is removed under a guard.
Run by tests/mac/ms6_r1_kernel_gate.sh with sandbox_macos.py, proc_darwin.py and r1_kernel_inner.py next to it.
argv: <sleeper binary>"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sandbox_macos  # noqa: E402

try:
    import proc_darwin  # noqa: E402
except ImportError:
    proc_darwin = None

TOKEN = "zb-probe-" + "ab" * 24
DENIED = "errno 1"  # EPERM: what Seatbelt returns for a denied operation (measured per row; see the gate log)
REPORT_DEADLINE_S = 20
failures = []


def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        failures.append(what)


def listen():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    s.listen(8)
    accepted = []

    def loop():
        while True:
            try:
                c, _ = s.accept()
            except OSError:
                return
            accepted.append(1)
            c.close()
    threading.Thread(target=loop, daemon=True).start()
    return s, accepted


def remove_scratch(path):
    real = os.path.realpath(path)
    base = os.path.realpath(tempfile.gettempdir())
    if os.path.dirname(real) == base and os.path.basename(real).startswith("zb-r1k-") and not os.path.islink(path):
        shutil.rmtree(real, ignore_errors=True)


def group_gone(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def read_line(fd, deadline):
    """One line from a raw fd, or None at the deadline or EOF: never an unbounded readline."""
    import select
    buf = b""
    while b"\n" not in buf:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            return None
        chunk = os.read(fd, 65536)
        if not chunk:
            return None
        buf += chunk
    return buf.split(b"\n", 1)[0].decode()


def run_inner(sleeper, port, decoy, plant=False, sandboxed=True, mode="report"):
    """Runs the inner (sandboxed or as the unsandboxed control) in its own process group; returns (report or None,
    census verdict or None, pgid gone afterwards)."""
    scratch = os.path.realpath(tempfile.mkdtemp(prefix="zb-r1k-"))
    canary = f"ANTHROPIC_BASE_URL=http://127.0.0.1:{port}"
    # The real interpreter, as setup runs it (/usr/bin/python3 is Apple's xcrun shim).
    cmd = [os.path.realpath(sys.executable), "-I", os.path.join(HERE, "r1_kernel_inner.py"), sleeper, str(port),
           str(decoy), canary, TOKEN if plant else "-", mode]
    env = {"PATH": "/usr/bin:/bin", "HOME": scratch, "LANG": "C", "PYTHONDONTWRITEBYTECODE": "1"}
    inner = None
    try:
        cm = sandbox_macos.setup_sandbox(scratch, [], cmd, loopback_port=port) if sandboxed else None
        argv = cm.__enter__() if cm is not None else cmd
        try:
            inner = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     env=env, start_new_session=True)
            line = read_line(inner.stdout.fileno(), time.monotonic() + REPORT_DEADLINE_S)
            report = json.loads(line) if line else None
            census = None
            if report is not None and proc_darwin is not None and hasattr(proc_darwin, "cli_env_clean"):
                census = proc_darwin.cli_env_clean(os.path.realpath(sleeper), os.getpid(), TOKEN.encode(),
                                                   canary.encode())
        finally:
            if cm is not None:
                cm.__exit__(None, None, None)
        return report, census
    finally:
        if inner is not None:
            pgid = inner.pid
            with_group_kill(pgid, inner)
        remove_scratch(scratch)


def with_group_kill(pgid, proc):
    """SIGKILL the inner's whole group and reap. macOS answers killpg with EPERM when the group's only member is an
    unreaped zombie leader, so: kill the group, kill and reap the leader, then kill the group again."""
    for _ in range(2):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        if proc.poll() is None:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
        proc.wait()
    for s in (proc.stdin, proc.stdout):
        try:
            s.close()
        except OSError:
            pass
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not group_gone(pgid):
        time.sleep(0.05)
    LAST_GROUP["gone"] = group_gone(pgid)


LAST_GROUP = {}


def main():
    sleeper = os.path.realpath(sys.argv[1])
    r1, _ = listen()
    decoy, decoy_accepted = listen()
    port, decoy_port = r1.getsockname()[1], decoy.getsockname()[1]
    try:
        # Harness self-test, unsandboxed so the inner is certainly alive: a live inner that never reports waits out the
        # whole deadline, fails, and leaves no member of its group.
        started = time.monotonic()
        report, _ = run_inner(sleeper, port, decoy_port, sandboxed=False, mode="silent")
        elapsed = time.monotonic() - started
        check(report is None and REPORT_DEADLINE_S - 1 <= elapsed < REPORT_DEADLINE_S + 10 and LAST_GROUP.get("gone"),
              f"harness: a live-silent inner fails at the deadline ({elapsed:.1f} s) and its whole group is reaped")

        control, _ = run_inner(sleeper, port, decoy_port, sandboxed=False)
        check(control is not None, f"control (no profile): the inner reported ({control})")
        if control is not None:
            for row in ("sibling_procargs2", "sibling_pidpath", "cli_procargs2", "cli_pidpath", "decoy_connect"):
                check(control[row] == "ok", f"control (no profile): {row} succeeds ({control[row]})")
            check(control["children_alive"] is True, "control: both targets were alive while read")
        decoy_before = len(decoy_accepted)

        report, census = run_inner(sleeper, port, decoy_port)
        if report is None:
            check(False, "inside: the inner probe under the setup profile reported (it died or stayed silent)")
        else:
            check(report["children_alive"] is True, "inside: both targets were alive while read")
            check(report["r1_connect"] == "ok", f"inside: the R1 port {port} is reachable ({report['r1_connect']})")
            check(report["decoy_connect"] == DENIED,
                  f"inside: the decoy port {decoy_port} is denied by Seatbelt ({report['decoy_connect']})")
            for who in ("sibling", "cli"):
                for call in ("procargs2", "pidpath"):
                    check(report[f"{who}_{call}"] == DENIED,
                          f"inside: {call} of the {who} is denied by Seatbelt ({report[f'{who}_{call}']})")
            check(len(decoy_accepted) == decoy_before, "the decoy listener accepted nothing from inside")
            if proc_darwin is None or not hasattr(proc_darwin, "cli_env_clean"):
                check(False, "outside: setup's census proc_darwin.cli_env_clean is missing (7021)")
            else:
                check(census is True, f"outside: setup's census finds the CLI stand-in and its canary ({census})")
                planted_report, planted = run_inner(sleeper, port, decoy_port, plant=True)
                positives = (planted_report is not None and planted_report["children_alive"] is True
                             and planted_report["r1_connect"] == "ok")
                check(positives, f"planted run: its own positives hold first ({planted_report})")
                check(positives and planted is False,
                      f"outside: a token in the CLI stand-in's environment is not clean ({planted})")
    finally:
        r1.close()
        decoy.close()
    if failures:
        print(f"FAIL\tms6-r1-kernel\t{len(failures)} failure(s)")
        return 1
    print("PASS\tms6-r1-kernel\tkernel properties")
    return 0


if __name__ == "__main__":
    sys.exit(main())
