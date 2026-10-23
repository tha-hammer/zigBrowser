#!/usr/bin/env python3
"""bd zigBrowser-3ui.12 (red cccb08fa): the shipped Linux browser must not hang on its first Zig environment
scan after GTK start when it was launched from a desktop.

Zig 0.16's start code hands main the libc envp array, and both Io instances (the app's and std.debug's) keep that
array with its startup length and scan it lazily, once (lib/std/Io/Threaded.zig scanEnviron). A desktop launcher
hands the browser DESKTOP_STARTUP_ID (and GIO_LAUNCHED_DESKTOP_FILE / _PID); gdk unsets them in gtk_init, and glibc's
unsetenv shifts the startup array in place, so its last slot becomes null. If the first scan comes after that, it
panics in Environ.scan ("attempt to use null value") while holding the Io mutex, and the panic handler re-enters the
scan and deadlocks: the GTK thread stops for good (bd 3ui.11 found this in the test runner).

Today the default launch is safe only by accident: webkit.preferHttp1's setenv("SOUP_FORCE_HTTP1") adds a NEW
variable before GTK starts, so glibc moves environ to a heap copy, and gdk's unsetenv then shifts the copy. A user
who opts out of it (ZIGBROWSER_HTTP2=1) and whose renderer variable is already set gets no setenv at all; and a
profile with saved pacing state makes the drawer core print nothing at startup. Then the first Zig print after GTK
start is the first scan.

Each case starts the real browser (drawer on, the default) with a private HOME, XDG dirs and --profile-dir, on its
own private Xvfb, below a held PID namespace with no network. Its profile holds valid pacing state and no
agent-drawer.json, so the startup load is silent. After the drawer icon row (GTK has started), the case makes
agent-drawer.json a directory, so the save after a drag fails, and drags the icon: zb_drawer_remember prints
"agent-drawer.json not saved" with std.debug.print, the first Zig print after GTK start. Required: that line
appears, no panic is printed, the icon moves on a second drag (the GTK thread is alive), and the browser runs.
  late-inherited          the four variables set, both startup setenvs skipped: the panic, then the hang, before
                          src/environ_guard.zig primed std.debug's scan first in main
  late-clean              the control: the same launch without the four variables (gdk unsets nothing)
  late-inherited-default  the four variables set, the default setenvs run: passes today by the accident above
Run: python3 tests/e2e/gtk_launch_env_product_test.py --binary zig-out/bin/zigBrowser [--only a,b]
     (registered: zig build test-gtk-launch-env, in test)
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
INHERITED = {
    "DESKTOP_STARTUP_ID": "zb-3ui12-launch_TIME1",
    "GIO_LAUNCHED_DESKTOP_FILE": "/usr/share/applications/zb-3ui12-launch.desktop",
    "GIO_LAUNCHED_DESKTOP_FILE_PID": "4242",
    "XDG_ACTIVATION_TOKEN": "zb-3ui12-launch-token",
}
NO_SETENV = {"ZIGBROWSER_HTTP2": "1", "WEBKIT_DMABUF_RENDERER_FORCE_SHM": "1"}
NOT_SAVED = "zigBrowser: agent-drawer.json not saved"
VALID_PACING = ('{"version":1,"day":20000,'
                '"social":{"actions_today":0,"daily_cap":50,"min_delay_ms":1000,"max_delay_ms":2000},'
                '"x":{"actions_today":0,"daily_cap":50,"min_delay_ms":1000,"max_delay_ms":2000}}')
RUN_PREFIX = "zb12-"

LAUNCH = ('script=$1; shift; exec 9</proc/self/ns/pid; exec /usr/bin/bwrap --unshare-net --die-with-parent --dev-bind / / --proc /proc -- '
          'unshare --user --map-root-user --pid --fork --mount-proc sh -c "\\"\\$@\\"; exit \\$?" sh '
          'env ZB_OUTER_PIDNS_FD=9 "$0" "$script" --sealed-child "$@"')


def private_session() -> Path:
    """A private HOME and XDG dirs, and one short runtime dir (TMPDIR and XDG_RUNTIME_DIR: the automation socket path
    must fit AF_UNIX). Refuses unless that dir is a fresh real directory named /tmp/zb12-XXXXXX, so an empty or odd
    value can never fall back to the real /run/user."""
    run = Path(tempfile.mkdtemp(prefix=RUN_PREFIX, dir="/tmp"))
    name = run.name
    if (run.parent != Path("/tmp") or not name.startswith(RUN_PREFIX) or len(name) != len(RUN_PREFIX) + 8
            or run.is_symlink() or not run.is_dir()):
        raise SystemExit(f"FAIL refusing: bad runtime dir {str(run)!r}")
    os.chmod(run, 0o700)
    home = run / "home"
    for d in (home / ".cache", home / ".config", home / ".local" / "share"):
        d.mkdir(parents=True)
    os.environ.update({"HOME": str(home), "XDG_CACHE_HOME": str(home / ".cache"),
                       "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local" / "share"),
                       "XDG_RUNTIME_DIR": str(run), "TMPDIR": str(run)})
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS", "ZIGBROWSER_SOCKET"):
        os.environ.pop(name, None)
    tempfile.tempdir = str(run)
    return run


def drag_after_gtk_start(binary: Path, tmp: Path, check, label: str, inherited: bool, extra: dict[str, str]) -> None:
    from agent_common import Browser, centre
    from slice2_common import isolate_profile_env

    env = isolate_profile_env(dict(os.environ))
    for name in (*INHERITED, "SOUP_FORCE_HTTP1", *NO_SETENV):
        env.pop(name, None)
    if inherited:
        env.update(INHERITED)
    env.update(extra)
    profile = tmp / f"p-{label}"
    profile.mkdir(parents=True)  # no agent-drawer.json: the startup load is silent (the default position)
    # Saved pacing state: the drawer core's loadPacing prints nothing at startup.
    (profile / "automation-pacing.json").write_text(VALID_PACING, encoding="utf-8")
    b = Browser(binary, tmp, label, [], profile=profile, automation=False, env=env)
    try:
        row = b.wait_row("icon", 1)
        if not check(row is not None, f"{label}: icon row (the drawer is on by default)", b):
            return
        check(NOT_SAVED not in "\n".join(b.err), f"{label}: nothing printed the save line before the drag", b)
        (profile / "agent-drawer.json").mkdir()  # only now, after GTK start: the save after the drag fails
        cx, cy = centre(row.rect())
        b.x.drag(cx, cy, cx - 100, cy - 100)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and NOT_SAVED not in "\n".join(b.err):
            time.sleep(0.1)
        check(NOT_SAVED in "\n".join(b.err), f"{label}: the failed save printed its line after GTK start", b)
        check("panic" not in "\n".join(b.err), f"{label}: no panic on stderr", b)
        moved = b.wait_row("icon", 1, count=2, timeout=15)
        if check(moved is not None, f"{label}: the first drag moved the icon", b):
            mx, my = centre(moved.rect())
            b.x.drag(mx, my, mx + 50, my)
            again = b.wait_row("icon", 1, count=3, timeout=15)
            check(again is not None and again.rect()[0] == moved.rect()[0] + 50,
                  f"{label}: a second drag still moves the icon (the GTK thread did not hang in the print)", b)
        check(b.proc.poll() is None, f"{label}: the browser is still running", b)
    finally:
        b.stop()


def case_late_inherited(binary: Path, tmp: Path, check) -> None:
    drag_after_gtk_start(binary, tmp, check, "late-inherited", True, NO_SETENV)


def case_late_clean(binary: Path, tmp: Path, check) -> None:
    drag_after_gtk_start(binary, tmp, check, "late-clean", False, NO_SETENV)


def case_late_inherited_default(binary: Path, tmp: Path, check) -> None:
    drag_after_gtk_start(binary, tmp, check, "late-inherited-default", True, {})


CASES = {"late-inherited": case_late_inherited, "late-clean": case_late_clean,
         "late-inherited-default": case_late_inherited_default}


def main() -> int:
    if "--sealed-child" not in sys.argv:
        return subprocess.run(["sh", "-c", LAUNCH, sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]]).returncode
    sys.argv.remove("--sealed-child")
    sys.path.insert(0, str(HERE.parents[1] / "agent" / "host" / "tests"))
    from pidns_guard import private_pid_namespace
    proven, why = private_pid_namespace()
    if not proven:
        print(f"FAIL refusing to start a browser outside a proven private PID namespace: {why}", flush=True)
        return 1
    run = private_session()
    try:
        from agent_common import run_main
        return run_main(__doc__, CASES)
    finally:
        import shutil
        if run.parent == Path("/tmp") and run.name.startswith(RUN_PREFIX):
            shutil.rmtree(run, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
