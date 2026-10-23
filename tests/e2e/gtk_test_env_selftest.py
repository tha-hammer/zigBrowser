"""bd zigBrowser-3ui.11: a Zig test step that runs GTK in-process fails cleanly and fast; it never hangs.

Two probe steps go through the SAME build.zig helper as the root.zig unit tests:
  * gtk-env-failure-probe (tests/gtk_env_failure_probe_test.zig): GTK starts, then a deliberate failure. Run with
    DESKTOP_STARTUP_ID, GIO_LAUNCHED_DESKTOP_FILE, GIO_LAUNCHED_DESKTOP_FILE_PID and XDG_ACTIVATION_TOKEN inherited
    (as a desktop-launched shell has them). gdk removes them at startup; with Zig 0.16 that turns the deliberate
    failure into a self-deadlock in the test runner. Required: exit 1, the deliberate failure reported by name, no
    timeout and no "attempt to use null value", within the outer bound.
  * gtk-hang-probe (tests/gtk_hang_probe_test.zig): GTK starts, then a test never returns. Required: exit 1 with that
    test named, within the outer bound (the step's own time bound ends it).
  * gtk-test-scope (SilverRidge 99a44f3 scope row): for the native Linux target and for x86_64-macos, aarch64-macos
    and x86_64-windows, the root unit-test run step as build.zig configured it. Required: only Linux is wrapped in
    `timeout` with its own environment lacking the four variables; macOS and Windows keep the exact plain run (no
    wrapper, environment unchanged). Configuring only, so it needs no Mac and no Windows host.
Each nested `zig build` runs under a private Xvfb (GTK only removes the variables once it reaches a display), a
private HOME and XDG dirs, and a hard outer timeout. The test relaunches itself below a held PID namespace (bwrap
--unshare-net + unshare) and proves it with pidns_guard before it starts Xvfb or a build, so every process it starts
dies with the namespace.

Run:  python3 tests/e2e/gtk_test_env_selftest.py --zig <zig> --cache-dir <dir> --global-cache-dir <dir>
"""
import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUTER_TIMEOUT_SEC = 300
INHERITED = {
    "DESKTOP_STARTUP_ID": "zb-3ui11-probe_TIME1",
    "GIO_LAUNCHED_DESKTOP_FILE": "/usr/share/applications/zb-3ui11-probe.desktop",
    "GIO_LAUNCHED_DESKTOP_FILE_PID": "4242",
    "XDG_ACTIVATION_TOKEN": "zb-3ui11-probe-token",
}

# As agent_previews_test.py: a shell holds this PID namespace as fd 9, bwrap gives a network namespace, and unshare a
# user and PID namespace below the held one; the inner shell keeps the test's exit status.
LAUNCH = ('script=$1; shift; exec 9</proc/self/ns/pid; exec /usr/bin/bwrap --unshare-net --die-with-parent --dev-bind / / --proc /proc -- '
          'unshare --user --map-root-user --pid --fork --mount-proc sh -c "\\"\\$@\\"; exit \\$?" sh '
          'env ZB_OUTER_PIDNS_FD=9 "$0" "$script" --sealed-child "$@"')


def guarded_kill(proc):
    """SIGKILL a child we started, only when its pid is a real int > 1."""
    pid = proc.pid
    if isinstance(pid, int) and pid > 1 and proc.poll() is None:
        os.kill(pid, signal.SIGKILL)
        proc.wait()


def guarded_kill_group(proc):
    """SIGKILL the process group a nested build leads (its build runner and test binary hold the output pipe, so
    killing the leader alone leaves communicate() waiting). Only a real pgid > 1 that is this child's own group, and
    only inside the PID namespace main() proved."""
    pid = proc.pid
    if not (isinstance(pid, int) and pid > 1):
        return
    try:
        pgid = os.getpgid(pid)
    except ProcessLookupError:
        return
    if pgid == pid and pgid > 1 and pgid != os.getpgrp():
        os.killpg(pgid, signal.SIGKILL)
    proc.wait()


def start_xvfb(scratch):
    """A private Xvfb on the first free display in 170..249; returns (proc, ':N')."""
    for n in range(170, 250):
        if Path(f"/tmp/.X{n}-lock").exists() or Path(f"/tmp/.X11-unix/X{n}").exists():
            continue
        log = open(Path(scratch) / f"xvfb-{n}.log", "wb")
        proc = subprocess.Popen(["Xvfb", f":{n}", "-nolisten", "tcp", "-screen", "0", "640x480x24"],
                                stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        log.close()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and proc.poll() is None:
            if Path(f"/tmp/.X11-unix/X{n}").exists():
                return proc, f":{n}"
            time.sleep(0.05)
        guarded_kill(proc)
    raise RuntimeError("no free X display in 170..249")


def nested_build(args, step, display, scratch, extra=()):
    """`zig build <step>` with the inherited variables set; returns (rc or None on the outer timeout, seconds, text)."""
    home = Path(scratch) / f"home-{step}"
    for d in (home / ".cache", home / ".config", home / ".local/share", home / "run"):
        d.mkdir(parents=True, exist_ok=True)
    os.chmod(home / "run", 0o700)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C.UTF-8", "HOME": str(home), "DISPLAY": display,
           "XDG_CACHE_HOME": str(home / ".cache"), "XDG_CONFIG_HOME": str(home / ".config"),
           "XDG_DATA_HOME": str(home / ".local/share"), "XDG_RUNTIME_DIR": str(home / "run"), **INHERITED}
    argv = [args.zig, "build", step, *extra, "-j4", "--summary", "none", "--cache-dir", args.cache_dir,
            "--global-cache-dir", args.global_cache_dir]
    start = time.monotonic()
    proc = subprocess.Popen(argv, cwd=ROOT, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=OUTER_TIMEOUT_SEC)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        guarded_kill_group(proc)
        out, _ = proc.communicate()
        rc = None
    return rc, time.monotonic() - start, out.decode("utf-8", "replace")


def check_failure_probe(rc, secs, text):
    problems = []
    if rc is None:
        problems.append(f"gtk-env-failure-probe did not finish within {OUTER_TIMEOUT_SEC} s (the step hangs)")
    elif rc != 1:
        problems.append(f"gtk-env-failure-probe exited {rc}, want 1")
    if "test.2 a deliberate failure after GTK start' failed" not in text:
        problems.append("the deliberate failure is not reported by name")
    for bad in ("timed out", "attempt to use null value", "terminated", "exited with code"):
        if bad in text:
            problems.append(f"output shows {bad!r}: the failure was not reported cleanly")
    if "test.1 GTK starts' failed" in text:
        problems.append("GTK did not start, so the probe proves nothing")
    return problems


def check_hang_probe(rc, secs, text):
    problems = []
    if rc is None:
        problems.append(f"gtk-hang-probe did not finish within {OUTER_TIMEOUT_SEC} s (a hang is not bounded)")
    elif rc != 1:
        problems.append(f"gtk-hang-probe exited {rc}, want 1")
    if "test.2 a test that never returns'" not in text:
        problems.append("the hanging test is not named in the output")
    if "test.1 GTK starts' failed" in text:
        problems.append("GTK did not start, so the probe proves nothing")
    return problems


SCOPE_ROWS = (
    # (label, extra zig build args, the required fields of the GTK-TEST-SCOPE line)
    ("linux-native", (), {"os": "linux", "wrapped": "1", "env": "own", "stripped": "4"}),
    ("x86_64-macos", ("-Dtarget=x86_64-macos",), {"os": "macos", "arch": "x86_64", "wrapped": "0", "env": "unchanged", "stripped": "0"}),
    ("aarch64-macos", ("-Dtarget=aarch64-macos",), {"os": "macos", "arch": "aarch64", "wrapped": "0", "env": "unchanged", "stripped": "0"}),
    ("x86_64-windows", ("-Dtarget=x86_64-windows",), {"os": "windows", "arch": "x86_64", "wrapped": "0", "env": "unchanged", "stripped": "0"}),
)


def check_scope(args, display, scratch):
    """The scope row: the root unit-test run step's configuration per target, read from build.zig's own graph."""
    problems = []
    for label, extra, want in SCOPE_ROWS:
        rc, secs, text = nested_build(args, "gtk-test-scope", display, scratch, extra)
        lines = [l for l in text.splitlines() if l.startswith("GTK-TEST-SCOPE\t")]
        print(f"gtk-test-scope {label}: rc={rc} after {secs:.0f} s: {lines[0] if lines else '(no line)'}", flush=True)
        if rc != 0 or len(lines) != 1:
            problems.append(f"scope {label}: rc={rc}, {len(lines)} GTK-TEST-SCOPE lines (want rc=0 and one line); "
                            f"output tail: {text.strip()[-300:]}")
            continue
        got = dict(field.split("=", 1) for field in lines[0].split("\t")[1:])
        wrong = {k: (got.get(k), v) for k, v in want.items() if got.get(k) != v}
        if wrong:
            problems.append(f"scope {label}: {wrong} (got, want)")
    return problems


def main():
    if "--sealed-child" not in sys.argv:
        return subprocess.run(["sh", "-c", LAUNCH, sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]]).returncode
    sys.argv.remove("--sealed-child")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", required=True)
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--global-cache-dir", required=True)
    args = parser.parse_args()
    args.cache_dir = str(Path(args.cache_dir).resolve())
    args.global_cache_dir = str(Path(args.global_cache_dir).resolve())
    sys.path.insert(0, str(ROOT / "agent" / "host" / "tests"))
    from pidns_guard import private_pid_namespace
    proven, why = private_pid_namespace()
    if not proven:
        print(f"FAIL refusing to start Xvfb or a build outside a proven private PID namespace: {why}", flush=True)
        return 1
    failures = []
    scratch = tempfile.mkdtemp(prefix="zb-3ui11-")
    try:
        xvfb, display = start_xvfb(scratch)
        try:
            failures += check_scope(args, display, scratch)
            for step, check in (("gtk-env-failure-probe", check_failure_probe), ("gtk-hang-probe", check_hang_probe)):
                rc, secs, text = nested_build(args, step, display, scratch)
                problems = check(rc, secs, text)
                print(f"{step}: rc={rc} after {secs:.0f} s", flush=True)
                if problems:
                    failures += [f"{step}: {p}" for p in problems] + [f"{step} output tail: {text.strip()[-600:]}"]
        finally:
            guarded_kill(xvfb)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if failures:
        print("FAIL\tgtk-test-env\n  " + "\n  ".join(failures), flush=True)
        return 1
    print("PASS\tgtk-test-env", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
