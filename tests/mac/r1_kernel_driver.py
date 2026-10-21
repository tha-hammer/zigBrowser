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
 5. the ::1 half (plan rev 19 endpoint contract; bead zigBrowser-v9f): this driver holds the reservation setup holds
    (::1:<port>, V6ONLY, never listening, no reuse): a second ::1 bind fails, and from inside the profile a connect
    to [::1]:<port> reaches nothing (macOS drops a SYN at a bound, non-listening socket: a timeout), never a
    completed connection;
 4. outside: setup's census proc_darwin.cli_env_clean finds the CLI stand-in and its canary (True); in a second run
    with a token planted in the stand-in's environment, whose own positives must hold first, it is False.
Process ownership: every inner runs in its own process group, every read has a local monotonic deadline, and the
whole group is SIGKILLed and reaped on every path; a live-silent inner is a bounded failure with no survivor (the
harness self-test). Every /tmp/zb-r1k-* scratch is removed under a guard.
Run by tests/mac/ms6_r1_kernel_gate.sh with sandbox_macos.py, proc_darwin.py and r1_kernel_inner.py next to it.
argv: <sleeper binary (the CLI stand-in)> <sibling binary (the same code at another path)>"""
import errno
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


def remove_scratch(path, rmtree=shutil.rmtree):
    """Removes exactly our /tmp/zb-r1k-* scratch; True only when the path is verifiably absent afterwards. Any error
    other than ENOENT is a failure (RoseCat 7055), never ignored."""
    real = os.path.realpath(path)
    base = os.path.realpath(tempfile.gettempdir())
    if os.path.dirname(real) != base or not os.path.basename(real).startswith("zb-r1k-") or os.path.islink(path):
        return False
    try:
        rmtree(real)
    except FileNotFoundError:
        pass
    except OSError:
        return False
    return not os.path.lexists(real)


def group_gone(pgid, killpg=os.killpg):
    """True only when the kernel says no process has this group (ESRCH). EPERM, or anything else, is not gone."""
    try:
        killpg(pgid, 0)
    except ProcessLookupError:
        return True
    except OSError:
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


def run_inner(sleeper, port, decoy, plant=False, sandboxed=True, mode="report", killpg=os.killpg,
              observe=os.killpg, rmtree=shutil.rmtree):
    """Runs the inner (sandboxed or as the unsandboxed control) in its own process group; returns (report or None,
    census verdict or None). CLEANUP records whether the group and the scratch are verifiably gone afterwards. The
    killpg/observe/rmtree parameters exist only for the harness's injected-failure self-tests."""
    scratch = os.path.realpath(tempfile.mkdtemp(prefix="zb-r1k-"))
    canary = f"ANTHROPIC_BASE_URL=http://127.0.0.1:{port}"
    # The real interpreter, as setup runs it (/usr/bin/python3 is Apple's xcrun shim).
    cmd = [os.path.realpath(sys.executable), "-I", os.path.join(HERE, "r1_kernel_inner.py"), sleeper, str(port),
           str(decoy), canary, TOKEN if plant else "-", mode, os.path.realpath(sys.argv[2])]
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
            if report is not None:
                PIDS["last"] = report.get("pids", [])
            census = None
            if report is not None and proc_darwin is not None and hasattr(proc_darwin, "cli_env_clean"):
                census = proc_darwin.cli_env_clean(os.path.realpath(sleeper), os.getpid(), TOKEN.encode(),
                                                   canary.encode())
        finally:
            if cm is not None:
                cm.__exit__(None, None, None)
        return report, census
    finally:
        # This run's exact resources (RoseCat 7065): the harness cleans up only these, never by a host-wide scan.
        CLEANUP.clear()
        CLEANUP.update(scratch=scratch, pgid=None if inner is None else inner.pid, pids=list(PIDS.pop("last", [])),
                       proc=inner)
        try:
            CLEANUP["group_gone"] = True if inner is None else with_group_kill(inner.pid, inner, killpg, observe)
        except Exception as exc:  # noqa: BLE001 - recorded, never allowed to skip the scratch removal below
            CLEANUP["group_gone"] = False
            CLEANUP["kill_error"] = repr(exc)
        finally:
            CLEANUP["scratch_gone"] = remove_scratch(scratch, rmtree)


def with_group_kill(pgid, proc, killpg=os.killpg, observe=os.killpg):
    """SIGKILL the inner's whole group and reap; True only when the group is verifiably gone (ESRCH). macOS answers
    killpg with EPERM while the group's only member is an unreaped zombie leader, so the leader is killed and reaped
    and the group killed again; an EPERM that persists after that means a member we cannot kill: not gone."""
    errors = []
    for _ in range(2):
        try:
            killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as exc:
            errors.append(exc.errno)
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
    while time.monotonic() < deadline and not group_gone(pgid, observe):
        time.sleep(0.05)
    return group_gone(pgid, observe)


CLEANUP = {}
PIDS = {}


def cleaned(label):
    """Every run, whatever it reported, must leave no group member and no scratch (RoseCat 7055)."""
    shown = {k: v for k, v in CLEANUP.items() if k != "proc"}
    check(CLEANUP.get("group_gone") is True and CLEANUP.get("scratch_gone") is True,
          f"{label}: no member of its process group and no scratch left ({shown})")


def exact_cleanup(resources, label):
    """After an injected-failure self-test, clean up EXACTLY what that run recorded (RoseCat 7065): its children's
    pids (each checked to still run our sleeper, so a reused pid is never killed), its process group, and its
    scratch path. Every kill, observation and removal must succeed, and each pid must be gone (ESRCH) within 5 s;
    anything else is red."""
    sleeper = os.path.realpath(sys.argv[1])
    survivors = []
    for pid in resources.get("pids", []):
        ps = subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True)
        if ps.returncode not in (0, 1):
            check(False, f"{label}: ps failed for pid {pid} (rc {ps.returncode})")
            continue
        if ps.stdout.strip() not in (sleeper, os.path.realpath(sys.argv[2])):
            continue  # already gone (rc 1, empty) or a reused pid that is not ours: never touched
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            continue
        except OSError as exc:
            check(False, f"{label}: SIGKILL of survivor {pid} failed ({exc})")
        survivors.append(pid)
    # The run's own leader first: killed survivors are its children, and they stay zombies (which still answer
    # kill(pid, 0)) until their parent is gone and they are re-parented and reaped.
    pgid, proc = resources.get("pgid"), resources.get("proc")
    if proc is not None and proc.poll() is None:  # the run's own leader (a raising kill never reached it)
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as exc:
            check(False, f"{label}: SIGKILL of its own group {pgid} failed ({exc})")
        proc.kill()
    if proc is not None:
        proc.wait()
        for stream in (proc.stdin, proc.stdout):
            try:
                stream.close()
            except OSError:
                pass
    deadline = time.monotonic() + 5
    alive = list(survivors)
    while alive and time.monotonic() < deadline:
        time.sleep(0.05)
        still = []
        for pid in alive:
            try:
                os.kill(pid, 0)
                still.append(pid)
            except ProcessLookupError:
                pass
            except OSError as exc:
                check(False, f"{label}: observing survivor {pid} failed ({exc})")
        alive = still
    check(not alive, f"{label}: the exact survivors {survivors} are gone (left: {alive})")
    if pgid is not None:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not group_gone(pgid):
            time.sleep(0.05)
        check(group_gone(pgid), f"{label}: its process group {pgid} is gone")
    scratch = resources.get("scratch")
    if scratch is not None:
        check(remove_scratch(scratch), f"{label}: its exact scratch {os.path.basename(scratch)} is removed")
    return survivors


def reserve_v6(port):
    """What setup's probe_r1 holds beside its listener (plan rev 19 endpoint contract (1); bead zigBrowser-v9f): an
    AF_INET6 IPV6_V6ONLY reservation on ::1:<port>, bound, never listening, no reuse flags."""
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    s.bind(("::1", port))
    return s


def v6_bind_errno(port):
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        try:
            s.bind(("::1", port))
        except OSError as exc:
            return exc.errno
        return 0


def main():
    sleeper = os.path.realpath(sys.argv[1])
    r1, _ = listen()
    decoy, decoy_accepted = listen()
    port, decoy_port = r1.getsockname()[1], decoy.getsockname()[1]
    reservation = reserve_v6(port)
    try:
        check(v6_bind_errno(port) == errno.EADDRINUSE,
              "the ::1 reservation holds: a second ::1 bind fails, even with SO_REUSEADDR+SO_REUSEPORT")
        # Harness self-tests, unsandboxed so the inner is certainly alive. A live inner with live children that never
        # reports waits out the whole deadline, fails, and leaves no member of its group and no scratch.
        started = time.monotonic()
        report, _ = run_inner(sleeper, port, decoy_port, sandboxed=False, mode="silent")
        elapsed = time.monotonic() - started
        check(report is None and REPORT_DEADLINE_S - 1 <= elapsed < REPORT_DEADLINE_S + 10,
              f"harness: a live-silent inner (with live children) fails at the deadline ({elapsed:.1f} s)")
        cleaned("harness: the live-silent inner")
        # Injected failures must be SEEN, never reported as clean: a kill that does not kill (the children live on),
        # a group observation that errors, a scratch deletion that fails. Each is then really cleaned up.
        def no_kill(pgid, sig):
            if sig != 0:
                raise PermissionError(1, "injected: killpg refused")
            return os.killpg(pgid, sig)

        def blind(pgid, sig):
            raise PermissionError(1, "injected: the group cannot be observed")

        def no_rmtree(path):
            raise PermissionError(13, "injected: rmtree refused")

        def raising_kill(pgid, sig):
            raise RuntimeError("injected: the group kill itself raises")

        # Foreign resources that look like ours: a matching scratch directory and a process running the same
        # sleeper, neither made by any injected run. The exact-scope cleanup must leave both alone.
        foreign_dir = os.path.realpath(tempfile.mkdtemp(prefix="zb-r1k-"))
        foreign = subprocess.Popen([sleeper, "120"])
        try:
            for label, kwargs, key in (("a kill that does not kill", {"killpg": no_kill}, "group_gone"),
                                       ("a group observation that errors", {"observe": blind}, "group_gone"),
                                       ("a scratch deletion that fails", {"rmtree": no_rmtree}, "scratch_gone"),
                                       ("a group kill that raises", {"killpg": raising_kill}, "group_gone")):
                report, _ = run_inner(sleeper, port, decoy_port, sandboxed=False, mode="report", **kwargs)
                seen = dict(CLEANUP)
                shown = {k: v for k, v in seen.items() if k != "proc"}
                check(report is not None and seen.get(key) is False, f"harness: {label} is detected ({shown})")
                if "raises" in label:
                    check(seen.get("scratch_gone") is True,
                          "harness: a raising group kill still removes the run's scratch (nested finally)")
                survivors = exact_cleanup(seen, f"harness cleanup after {label}")
                if label == "a kill that does not kill":
                    check(len(survivors) == 2, f"harness: the refused kill really left the 2 children ({survivors})")
            check(os.path.isdir(foreign_dir), "harness: a foreign zb-r1k-* directory survives the exact cleanup")
            check(foreign.poll() is None, "harness: a foreign process running the same sleeper survives")
        finally:
            foreign.kill()
            foreign.wait()
            os.rmdir(foreign_dir)


        control, _ = run_inner(sleeper, port, decoy_port, sandboxed=False)
        cleaned("control")
        check(control is not None, f"control (no profile): the inner reported ({control})")
        if control is not None:
            for row in ("sibling_procargs2", "sibling_pidpath", "cli_procargs2", "cli_pidpath", "decoy_connect"):
                check(control[row] == "ok", f"control (no profile): {row} succeeds ({control[row]})")
            check(control["v6_connect"] == "timeout",
                  f"control (no profile): the reservation alone makes [::1]:<port> unreachable ({control['v6_connect']})")
            check(control["children_alive"] is True, "control: both targets were alive while read")
        decoy_before = len(decoy_accepted)

        report, census = run_inner(sleeper, port, decoy_port)
        cleaned("inside")
        if report is None:
            check(False, "inside: the inner probe under the setup profile reported (it died or stayed silent)")
        else:
            check(report["children_alive"] is True, "inside: both targets were alive while read")
            check(report["r1_connect"] == "ok", f"inside: the R1 port {port} is reachable ({report['r1_connect']})")
            # macOS (both arches, measured; the control too) silently drops a SYN that reaches a bound,
            # non-listening socket, so the reservation makes [::1]:<port> unreachable: a timeout, never a completed
            # connection to anyone.
            check(report["v6_connect"] == "timeout",
                  f"inside: [::1]:{port} reaches nothing (the reservation drops it), never a foreign listener "
                  f"({report['v6_connect']})")
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
                cleaned("planted run")
                positives = (planted_report is not None and planted_report["children_alive"] is True
                             and planted_report["r1_connect"] == "ok")
                check(positives, f"planted run: its own positives hold first ({planted_report})")
                check(positives and planted is False,
                      f"outside: a token in the CLI stand-in's environment is not clean ({planted})")
    finally:
        r1.close()
        decoy.close()
        reservation.close()
    if failures:
        print(f"FAIL\tms6-r1-kernel\t{len(failures)} failure(s)")
        return 1
    print("PASS\tms6-r1-kernel\tkernel properties")
    return 0


if __name__ == "__main__":
    sys.exit(main())
