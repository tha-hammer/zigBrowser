"""The display guard (orchestrator HARD RULE, 2026-10-15): no build or test step that
can start a browser or a GTK window may run on a display that is not a private Xvfb.

On 2026-10-15 a `zig build test` in the worktree, with the inherited DISPLAY=:0 and no
Xvfb, opened blank zigBrowser windows on the user's real screen. Every step that
`zig build` runs for a top-level step (all but the install steps, `agent-runtime` and
`mac-gate`; `run` too, RoseCat 5625) now depends on tools/display_guard.py, which refuses
unless DISPLAY is unset or names an X server whose lock belongs to an Xvfb, and no
WAYLAND_DISPLAY is set; ZB_ALLOW_REAL_DISPLAY=1 overrides it.

    python3 tests/display_guard_test.py --zig ZIG [--cache-dir DIR]

The unit part feeds the guard fake X locks and a fake /proc. The build part runs the
harmless `display-guard-probe` step (it only prints a line) and `zig build run --
--version` (the browser prints its version before GTK starts), so a missing guard can
never open a window: DISPLAY there names no server at all."""

import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
GUARD = REPO / "tools" / "display_guard.py"
PROBE_LINE = "display-guard-probe ran"
NO_SERVER = ":4242"  # no X server: even an unguarded step could not draw anywhere
ZIG = "zig"
CACHE_DIR = None


def load_guard():
    spec = importlib.util.spec_from_file_location("display_guard", GUARD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class VerdictTest(unittest.TestCase):
    def setUp(self):
        self.guard = load_guard()
        self.root = Path(tempfile.mkdtemp(prefix="zb-display-guard-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.tmp, self.proc = self.root / "tmp", self.root / "proc"
        self.tmp.mkdir()
        self.proc.mkdir()

    def server(self, number, pid, comm):
        (self.tmp / f".X{number}-lock").write_text(f"{pid:>10}\n")
        (self.proc / str(pid)).mkdir()
        (self.proc / str(pid) / "comm").write_text(comm + "\n")

    def refusal(self, env):
        return self.guard.refusal(env, tmp_dir=self.tmp, proc_dir=self.proc)

    def test_no_display_is_allowed(self):
        self.assertIsNone(self.refusal({}))
        self.assertIsNone(self.refusal({"DISPLAY": ""}))

    def test_a_private_xvfb_is_allowed(self):
        self.server(99, 4321, "Xvfb")
        self.assertIsNone(self.refusal({"DISPLAY": ":99"}))
        self.assertIsNone(self.refusal({"DISPLAY": ":99.0"}))

    def test_the_real_screen_is_refused(self):
        self.server(0, 1111, "Xorg")
        for display in (":0", ":0.0"):
            with self.subTest(display=display):
                line = self.refusal({"DISPLAY": display})
                self.assertIn(f"DISPLAY={display} is not a private Xvfb", line)
                self.assertIn("xvfb-run", line)
                self.assertIn("ZB_ALLOW_REAL_DISPLAY=1", line)

    def test_a_display_without_a_live_xvfb_lock_is_refused(self):
        (self.tmp / ".X7-lock").write_text("   9999999\n")  # a stale lock: no such process
        self.server(8, 2222, "Xvfb-not")
        for display in (":5", ":7", ":8", "localhost:10.0", "host:0", "unix:0", ":x", "0"):
            with self.subTest(display=display):
                self.assertIsNotNone(self.refusal({"DISPLAY": display}))

    def test_wayland_is_refused_even_with_a_private_xvfb(self):
        self.server(99, 4321, "Xvfb")
        self.assertIn("WAYLAND_DISPLAY", self.refusal({"DISPLAY": ":99", "WAYLAND_DISPLAY": "wayland-0"}))
        self.assertIn("WAYLAND_DISPLAY", self.refusal({"WAYLAND_DISPLAY": "wayland-0"}))

    def test_the_override_allows_any_display(self):
        self.server(0, 1111, "Xorg")
        for env in ({"DISPLAY": ":0"}, {"WAYLAND_DISPLAY": "wayland-0"}):
            with self.subTest(env=env):
                self.assertIsNone(self.refusal({**env, "ZB_ALLOW_REAL_DISPLAY": "1"}))
        self.assertIsNotNone(self.refusal({"DISPLAY": ":0", "ZB_ALLOW_REAL_DISPLAY": "yes"}))


class BuildStepTest(unittest.TestCase):
    """The guard sits in front of the build's steps, not only in a script."""

    def probe(self, *step, **env):
        base = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", "/tmp"),
                "LANG": "C.UTF-8"}
        cache = ["--cache-dir", CACHE_DIR] if CACHE_DIR else []
        done = subprocess.run([ZIG, "build", *(step or ("display-guard-probe",)), *cache], cwd=REPO,
                              env={**base, **env}, capture_output=True, text=True, timeout=1200)
        return done.returncode, done.stdout + done.stderr

    def test_zig_build_run_is_guarded_too(self):
        """RoseCat 5625: `run` starts the browser, so it waits for the guard like every step."""
        code, out = self.probe("run", "--", "--version", DISPLAY=NO_SERVER)
        self.assertNotEqual(code, 0, out)
        self.assertNotIn("WebKitGTK", out)
        self.assertIn(f"DISPLAY={NO_SERVER} is not a private Xvfb", out)
        code, out = self.probe("run", "--", "--version", DISPLAY=NO_SERVER, ZB_ALLOW_REAL_DISPLAY="1")
        self.assertEqual(code, 0, out)
        self.assertIn("WebKitGTK", out)

    def test_a_display_that_is_not_a_private_xvfb_stops_the_step(self):
        code, out = self.probe(DISPLAY=NO_SERVER)
        self.assertNotEqual(code, 0, out)
        self.assertNotIn(PROBE_LINE, out)
        self.assertIn(f"DISPLAY={NO_SERVER} is not a private Xvfb", out)

    def test_wayland_stops_the_step(self):
        code, out = self.probe(WAYLAND_DISPLAY="wayland-zb-guard-test")
        self.assertNotEqual(code, 0, out)
        self.assertNotIn(PROBE_LINE, out)

    def test_no_display_or_the_override_lets_the_step_run(self):
        for env in ({}, {"DISPLAY": NO_SERVER, "ZB_ALLOW_REAL_DISPLAY": "1"}):
            with self.subTest(env=env):
                code, out = self.probe(**env)
                self.assertEqual(code, 0, out)
                self.assertIn(PROBE_LINE, out)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--cache-dir")
    args, rest = parser.parse_known_args()
    ZIG, CACHE_DIR = args.zig, args.cache_dir
    unittest.main(argv=[sys.argv[0], *rest])
