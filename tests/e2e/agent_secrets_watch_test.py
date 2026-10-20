"""The teardown test's X watcher reads a vanished window as not viewable (RoseCat 6321 SHOULD on
34a973d; plan rev 16.18.10).

agent_secrets_shutdown_test.Watch.viewable() asks the X server for a window's map state. A
window can be destroyed between the test's choice of it and that request; the server then
answers BadWindow, and Xlib's default error handler ends the whole test process (the
process-wide handler xinput.py installs passes this request's errors on to it). viewable()
must trap BadWindow and BadDrawable for its own request only, answer False, and leave the
process's error handler as it found it.

Here: a private Xvfb with no browser and no window manager (xsession.Display), a Watch on it,
and windows that do not exist. Run alone, as the gate runs each module."""

import ctypes
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_secrets_shutdown_test as shutdown  # noqa: E402
from xsession import Display  # noqa: E402

X = ctypes.CDLL("libX11.so.6")
X.XSetErrorHandler.restype = ctypes.c_void_p
X.XSetErrorHandler.argtypes = [ctypes.c_void_p]


class _Browser:
    """Just what Watch reads from a browser: its display file."""

    def __init__(self, display_file: Path) -> None:
        self.display_file = display_file


def child(display_file: str) -> int:
    """The checks themselves, in a child process: Xlib's default handler ends the process it
    runs in, so the parent survives to report it and to clean up."""
    failures = []
    watch = shutdown.Watch(_Browser(Path(display_file)))
    try:
        before = X.XSetErrorHandler(None)
        X.XSetErrorHandler(before)  # read the process's handler back, unchanged
        for window in (0x1FFFFFFF, 0x00400001, 0x7FFFFFFF):
            got = watch.viewable(window)
            if got is not False:
                failures.append(f"window {window:#x}: viewable() gave {got!r}, want False")
        after = X.XSetErrorHandler(None)
        X.XSetErrorHandler(after)
        if after != before:
            failures.append("viewable() left a different process-wide X error handler")
        root = shutdown.X.XDefaultRootWindow(watch.dpy)
        if watch.viewable(root) is not True:
            failures.append("the root window is not viewable")
    finally:
        watch.close()
    for f in failures:
        print("FAIL", f, flush=True)
    return 1 if failures else 0


def main() -> int:
    import subprocess
    if sys.argv[1:2] == ["--child"]:
        return child(sys.argv[2])
    display = Display("640x480x24")
    tmp = Path(tempfile.mkdtemp(prefix="zb-watch-"))
    try:
        (tmp / "display").write_text(f"DISPLAY=:{display.number}\nXAUTHORITY={display.auth}\n", encoding="utf-8")
        done = subprocess.run([sys.executable, __file__, "--child", str(tmp / "display")], capture_output=True,
                              text=True, timeout=60)
    finally:
        display.close()
        for p in sorted(tmp.rglob("*"), reverse=True):
            p.unlink()
        tmp.rmdir()
    print(done.stdout, end="")
    if done.returncode != 0:
        if "FAIL" not in done.stdout:
            print("FAIL the checks' process ended (rc", done.returncode, "):", done.stderr.strip().splitlines()[:2])
        return 1
    print("ok   viewable() traps BadWindow and keeps the process's X error handler")
    return 0


if __name__ == "__main__":
    sys.exit(main())
