"""bd zigBrowser-3ui.6: a relative ZIGBROWSER_SOCKET is refused with a clear error and a non-zero exit, never a panic.

The browser used to pass ZIGBROWSER_SOCKET straight to automation_server's cleanupSocketPath, whose
deleteFileAbsolute asserts an absolute path, so `ZIGBROWSER_SOCKET=s/abc.sock zigBrowser --automation-api` reached
`unreachable` and aborted. A unix socket bound at a relative path also depends on the cwd, so a client cannot find it
reliably; the chosen behaviour is to REFUSE it (not to resolve it against the cwd).

This runs the REAL binary: --automation-api, an explicit --profile-dir, a private HOME and XDG dirs, a short private
XDG_RUNTIME_DIR under /tmp, a private Xvfb on a free high display (never :0), cwd = a private dir holding `s/`, and
ZIGBROWSER_SOCKET=s/abc.sock. It requires: exit status 1 (not a signal), the fixed stderr line, no panic text, and
no socket or token file created under the cwd. Teardown may signal (a hung browser, Xvfb), so the test first
relaunches itself below a held PID namespace and proves it with pidns_guard before starting anything.

Run:  python3 tests/e2e/automation_relative_socket_test.py --binary zig-out/bin/zigBrowser
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
REFUSAL = "zigBrowser: ZIGBROWSER_SOCKET must be an absolute path"
RELATIVE = "s/abc.sock"
TIMEOUT_SEC = 30.0

# As agent_previews_test.py: a shell holds this PID namespace as fd 9, bwrap gives a network namespace, and unshare a
# user and PID namespace below the held one; the inner shell keeps the test's exit status.
LAUNCH = ('script=$1; shift; exec 9</proc/self/ns/pid; exec /usr/bin/bwrap --unshare-net --die-with-parent --dev-bind / / --proc /proc -- '
          'unshare --user --map-root-user --pid --fork --mount-proc sh -c "\\"\\$@\\"; exit \\$?" sh '
          'env ZB_OUTER_PIDNS_FD=9 "$0" "$script" --sealed-child "$@"')


def guarded_kill(proc):
    """SIGKILL a child we started, only when its pid is a real int > 1 (never a mocked or init pid)."""
    pid = proc.pid
    if isinstance(pid, int) and pid > 1 and proc.poll() is None:
        os.kill(pid, signal.SIGKILL)
        proc.wait()


def start_xvfb(scratch):
    """A private Xvfb on the first free display in 170..249; returns (proc, ':N')."""
    for n in range(170, 250):
        if Path(f"/tmp/.X{n}-lock").exists() or Path(f"/tmp/.X11-unix/X{n}").exists():
            continue
        log = open(Path(scratch) / f"xvfb-{n}.log", "wb")
        proc = subprocess.Popen(["Xvfb", f":{n}", "-nolisten", "tcp", "-screen", "0", "1024x768x24"],
                                stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        log.close()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and proc.poll() is None:
            if Path(f"/tmp/.X11-unix/X{n}").exists():
                return proc, f":{n}"
            time.sleep(0.05)
        guarded_kill(proc)
    raise RuntimeError("no free X display in 170..249")


def run_case(binary):
    failures = []
    runtime = tempfile.mkdtemp(prefix="zb36-", dir="/tmp")  # short: an AF_UNIX path must fit in sun_path
    with tempfile.TemporaryDirectory(prefix="zb-relsock-") as scratch:
        home, cwd = Path(scratch) / "home", Path(scratch) / "cwd"
        for d in (home / ".cache", home / ".config", home / ".local/share", cwd / "s"):
            d.mkdir(parents=True)
        os.chmod(runtime, 0o700)
        xvfb, display = start_xvfb(scratch)
        try:
            env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": str(home), "DISPLAY": display,
                   "XDG_CACHE_HOME": str(home / ".cache"), "XDG_CONFIG_HOME": str(home / ".config"),
                   "XDG_DATA_HOME": str(home / ".local/share"), "XDG_RUNTIME_DIR": runtime,
                   "ZIGBROWSER_SOCKET": RELATIVE}
            proc = subprocess.Popen([str(binary), "about:blank", "--automation-api", "--profile-dir",
                                     str(Path(scratch) / "profile")],
                                    cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE)
            try:
                _, err = proc.communicate(timeout=TIMEOUT_SEC)
            except subprocess.TimeoutExpired:
                guarded_kill(proc)
                _, err = proc.communicate()
                failures.append(f"the browser was still running after {TIMEOUT_SEC:.0f} s with a relative socket")
            text = err.decode("utf-8", "replace")
            if proc.returncode != 1:
                failures.append(f"exit status {proc.returncode}, want 1 (a negative status is a signal)")
            if REFUSAL not in text:
                failures.append(f"stderr lacks {REFUSAL!r}")
            for marker in ("panic", "reached unreachable code"):
                if marker in text:
                    failures.append(f"stderr shows {marker!r}")
            left = sorted(str(p.relative_to(cwd)) for p in cwd.rglob("*") if p.name != "s")
            if left:
                failures.append(f"files were created under the cwd: {left}")
            if failures:
                failures.append("stderr tail: " + text.strip()[-400:])
        finally:
            guarded_kill(xvfb)
            shutil.rmtree(runtime, ignore_errors=True)
    return failures


def main():
    if "--sealed-child" not in sys.argv:
        return subprocess.run(["sh", "-c", LAUNCH, sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]]).returncode
    sys.argv.remove("--sealed-child")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(HERE.parents[1] / "agent" / "host" / "tests"))
    from pidns_guard import private_pid_namespace
    proven, why = private_pid_namespace()
    if not proven:
        print(f"FAIL refusing to start a browser outside a proven private PID namespace: {why}", flush=True)
        return 1
    binary = Path(args.binary).resolve()
    if not binary.is_file():
        print(f"FAIL no binary at {binary}", flush=True)
        return 1
    failures = run_case(binary)
    if failures:
        print("FAIL\tautomation-relative-socket\n  " + "\n  ".join(failures), flush=True)
        return 1
    print("PASS\tautomation-relative-socket", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
