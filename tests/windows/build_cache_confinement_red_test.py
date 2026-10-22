#!/usr/bin/env python3
r"""bd zigBrowser-ong.11 red (UNREGISTERED until the green, which moves these cases into
build_on_windows_selftest.py, step windows-build-selftest): the Windows build keeps BOTH Zig caches under
%USERPROFILE%\zb.

Found on the 2026-10-22 WS2a.0 Win11 run: build-on-windows.sh never sets ZIG_GLOBAL_CACHE_DIR, so every build
writes Zig's global cache to C:\Users\<user>\AppData\Local\zig, outside the allowed C:\Users\<user>\zb.

Runs the REAL tests/windows/build-on-windows.sh against the existing selftest's fake git/ssh/scp/timeout (no
host, no network, no display), decodes the exact -EncodedCommand the build ssh call carries, and checks the
command the host would run:
  * ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR are each assigned exactly once, BEFORE `zig build`;
  * each value, resolved against USERPROFILE=C:\Users\zbtext, is under C:\Users\zbtext\zb\ (no `..`, no other
    variable); the local cache is inside this run's own folder zb\build\run-<sha>.
PowerShell is not installed on Linux, so the assignment form is resolved here; the host run of the next
approved build proves the real PowerShell semantics.

Run alone:  python3 -I tests/windows/build_cache_confinement_red_test.py -v
"""
import importlib.util
import pathlib
import re
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("build_on_windows_selftest", HERE / "build_on_windows_selftest.py")
_sel = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_sel)

USERPROFILE = "C:\\Users\\zbtext"
ZB_ROOT = USERPROFILE + "\\zb\\"
# `$env:NAME = Join-Path $env:USERPROFILE '<relative>'` — the one accepted form.
ASSIGN = re.compile(r"^\s*\$env:(ZIG_GLOBAL_CACHE_DIR|ZIG_LOCAL_CACHE_DIR)\s*=\s*(.+?)\s*$")
JOIN = re.compile(r"^Join-Path\s+\$env:USERPROFILE\s+'([^']*)'$")


def resolve(expr):
    """The value an assignment's right-hand side gives under USERPROFILE, or None if not the accepted form."""
    m = JOIN.match(expr)
    if not m:
        return None
    rel = m.group(1)
    if not rel or "$" in rel or "%" in rel or rel.startswith("\\") or re.match(r"^[A-Za-z]:", rel):
        return None
    parts = [p for p in rel.replace("/", "\\").split("\\") if p]
    if any(p in (".", "..") for p in parts):
        return None
    return USERPROFILE + "\\" + "\\".join(parts)


class ZigCachesStayUnderZb(_sel._Case):
    def _build_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            td = pathlib.Path(tmp)
            proc = self._run(td)
            self.assertEqual(proc.returncode, 0, f"the faked build must succeed: {proc.stderr}")
            cmd = self._decoded_build(td)
        self.assertTrue(cmd, "no -EncodedCommand build call was recorded")
        return cmd

    def test_both_zig_caches_are_set_under_zb_before_zig_build(self):
        lines = self._build_command().splitlines()
        build_at = next((i for i, ln in enumerate(lines) if re.search(r"zig[^']*'\)?\s+build\b|zig\.exe'\s+build", ln)), None)
        self.assertIsNotNone(build_at, f"no zig build line in the command: {lines}")
        seen = {}
        for i, ln in enumerate(lines):
            m = ASSIGN.match(ln)
            if m:
                self.assertNotIn(m.group(1), seen, f"{m.group(1)} assigned twice")
                seen[m.group(1)] = (i, m.group(2))
        for name in ("ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR"):
            with self.subTest(var=name):
                self.assertIn(name, seen, f"{name} is never set: Zig falls back to a cache outside zb\\")
                at, expr = seen[name]
                self.assertLess(at, build_at, f"{name} must be set before zig build")
                value = resolve(expr)
                self.assertIsNotNone(value, f"{name} = {expr!r} is not Join-Path $env:USERPROFILE '<zb\\...>'")
                self.assertTrue(value.startswith(ZB_ROOT), f"{name} resolves to {value}, outside {ZB_ROOT}")

    def test_local_cache_is_inside_this_runs_folder(self):
        cmd = self._build_command()
        expr = next((m.group(2) for m in map(ASSIGN.match, cmd.splitlines()) if m and m.group(1) == "ZIG_LOCAL_CACHE_DIR"), None)
        self.assertIsNotNone(expr, "ZIG_LOCAL_CACHE_DIR is never set")
        value = resolve(expr) or ""
        self.assertTrue(value.startswith(ZB_ROOT + "build\\run-" + _sel.FAKE_SHA + "\\"),
                        f"ZIG_LOCAL_CACHE_DIR resolves to {value!r}, not inside zb\\build\\run-<sha>")

    def test_resolver_refuses_escapes(self):
        # The checker itself must not accept an escape (a guard on the guard).
        for bad in ("Join-Path $env:USERPROFILE 'zb\\..\\AppData\\Local\\zig'",
                    "Join-Path $env:LOCALAPPDATA 'zig'",
                    "Join-Path $env:USERPROFILE 'C:\\Windows\\Temp'",
                    "Join-Path $env:USERPROFILE ''",
                    "'C:\\Users\\zbtext\\zb\\x'"):
            with self.subTest(expr=bad):
                v = resolve(bad)
                self.assertTrue(v is None or not v.startswith(ZB_ROOT), f"{bad!r} resolved to {v!r}")
        self.assertEqual(resolve("Join-Path $env:USERPROFILE 'zb\\zig-global-cache'"), ZB_ROOT + "zig-global-cache")


if __name__ == "__main__":
    unittest.main()
