r"""Live Windows PathResolver / containment oracle on the Win11 VM (bead zigBrowser-d1d, part 1).

`wincontain.normalize_within` is purely lexical and cannot see a junction, so a path lexically inside a root
can resolve OUTSIDE it (`root\\j` -> `C:\\Windows`). `wincontain.resolved_within` closes that with an injected
handle-based resolver (CreateFileW + GetFinalPathNameByHandleW). This test asks Windows itself: it builds a
junction tree on the VM, resolves each path through the REAL API (tests/windows/finalpath_oracle.py), and
asserts:

  * `normalize_final_path` turns the REAL `\\?\C:\...` output into the expected drive-form path (named d1d red
    "real GetFinalPathNameByHandleW output vs normalize_final_path");
  * `resolved_within` ALLOWS a genuinely in-root file and an in-root junction, and DENIES a junction that
    escapes the root (-> C:\Windows) and an unfollowable junction (-> a missing target, fail closed).

A lexical-only resolver would ALLOW the escaping junction; the real resolver denies it — that is the live red.

Skips cleanly (exit 0) when ZB_WIN11_HOST is unset, so it is safe in a hostless Linux gate. Needs no Linux
slot — the work runs on the VM. All writes stay under C:\Users\<user>\zb\.

Run live:  ZB_WIN11_HOST=127.0.0.1 ZB_WIN11_PORT=2222 python3 tests/windows/wincontain_resolve_live_test.py -v
"""
import base64
import json
import os
import pathlib
import secrets
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "windows"))
import live_gate  # noqa: E402  ZB_WIN_GATE=1: a missing host fails instead of skipping; prints ASSERTS <n>

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "agent" / "host"))
from zb_agent_host import wincontain as wc  # noqa: E402


class _LiveResolver:
    """A wincontain.PathResolver backed by the VM oracle's real GetFinalPathNameByHandleW results.

    The real OS handle lived (and was closed) on the VM, so here `handle` is a non-None sentinel: this
    increment proves name-level resolution + containment against the real API. Handle-based TOCTOU-safe USE
    (acting through the pinned handle vs. reopening the name) is a separate d1d red."""

    def __init__(self, finals):
        self._finals = finals  # {path: raw_final_or_None}

    def resolve(self, path):
        if path not in self._finals:
            raise wc.ContainError(f"path not resolved by the oracle: {path!r}")
        final = self._finals[path]
        if not final:
            raise wc.ContainError(f"CreateFileW could not follow/open {path!r} (fail closed)")
        return wc.ResolvedPath(wc.normalize_final_path(final), handle=object())


class ResolveLiveOracle(unittest.TestCase):
    def setUp(self):
        self.host = os.environ.get("ZB_WIN11_HOST")
        if not self.host:
            live_gate.skip_or_fail(self, "ZB_WIN11_HOST unset — live VM resolve oracle skipped")
        self.port = os.environ.get("ZB_WIN11_PORT", "2222")
        self.user = os.environ.get("ZB_WIN11_USER", "zbtext")
        self.key = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
        self.kh = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")

    def _scrub(self, *cmd):
        return ["env", "-u", "DISPLAY", "-u", "WAYLAND_DISPLAY", "-u", "XAUTHORITY", *cmd]

    def _ssh(self, *args):
        base = ["ssh", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-p", self.port, f"{self.user}@{self.host}"]
        return subprocess.run(self._scrub(*base, *args), capture_output=True, text=True, timeout=120)

    def _scp(self, local, remote):
        base = ["scp", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-P", self.port, local, f"{self.user}@{self.host}:{remote}"]
        return subprocess.run(self._scrub(*base), capture_output=True, text=True, timeout=120)

    def _ps(self, script):
        """Run a PowerShell script on the VM as a base64 -EncodedCommand, so no quoting survives ssh/cmd."""
        enc = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        return self._ssh("powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", enc)

    def test_resolved_within_denies_junction_escape_against_the_real_api(self):
        # Absolute profile dir on the VM, so the oracle gets fully-qualified paths. Read it through the
        # EncodedCommand path (Console.Write, no newline): `cmd /c echo %USERPROFILE%` over ssh picks up a
        # stray trailing quote from Windows-OpenSSH argument reconstruction, which would unbalance the setup.
        prof = self._ps("[Console]::Out.Write($env:USERPROFILE)")
        profile = prof.stdout.strip()
        self.assertRegex(profile, r"^[A-Za-z]:\\[^\"]*$", f"unexpected profile path {profile!r}")

        rel = f"zb\\resolve-{os.getpid()}-{secrets.token_hex(4)}"
        base = f"{profile}\\{rel}"
        root = f"{base}\\root"
        legit = f"{root}\\sub\\f.txt"
        j_escape = f"{root}\\jwin"            # junction -> C:\Windows (escapes root)
        j_inroot = f"{root}\\jin"             # junction -> root\sub (stays in root)
        j_bad = f"{root}\\jbad"               # junction -> a missing target (unfollowable -> fail closed)
        missing_target = f"{profile}\\zb\\does-not-exist-{secrets.token_hex(4)}"

        # Build the tree via PowerShell (base64, no quoting survives ssh). mklink /J (a junction) needs no
        # admin, unlike a symlink; cmd's mklink also allows a junction to a not-yet-existing target (jbad).
        setup = (
            f"$ErrorActionPreference='Stop'\n"
            f"New-Item -ItemType Directory -Force -Path '{root}\\sub' | Out-Null\n"
            f"Set-Content -LiteralPath '{legit}' -Value 'hi' -NoNewline\n"
            f"cmd /c mklink /J \"{j_escape}\" \"C:\\Windows\" | Out-Null\n"
            f"cmd /c mklink /J \"{j_inroot}\" \"{root}\\sub\" | Out-Null\n"
            f"cmd /c mklink /J \"{j_bad}\" \"{missing_target}\" | Out-Null\n"
            f"if (-not (Test-Path -LiteralPath '{j_escape}')) {{ throw 'jwin not created' }}\n"
            f"if (-not (Test-Path -LiteralPath '{legit}')) {{ throw 'legit file not created' }}\n"
            f"Write-Output 'SETUP_OK'\n"
        )
        mk = self._ps(setup)
        self.assertIn("SETUP_OK", mk.stdout, f"tree setup failed: rc={mk.returncode}\n{mk.stdout}\n{mk.stderr}")

        paths = [root, legit, j_escape, j_inroot, j_bad]
        try:
            with tempfile.TemporaryDirectory() as t:
                td = pathlib.Path(t)
                (td / "paths.json").write_text(json.dumps({"paths": paths}), encoding="utf-8")
                r = self._scp(str(td / "paths.json"), f"{rel.replace(chr(92), '/')}/paths.json")
                self.assertEqual(r.returncode, 0, f"scp paths failed: {r.stderr}")
                r = self._scp(str(REPO / "tests" / "windows" / "finalpath_oracle.py"),
                              f"{rel.replace(chr(92), '/')}/finalpath_oracle.py")
                self.assertEqual(r.returncode, 0, f"scp oracle failed: {r.stderr}")
                run = self._ssh("python", f"{base}\\finalpath_oracle.py", f"{base}\\paths.json")
                self.assertEqual(run.returncode, 0, f"oracle failed: {run.stdout}\n{run.stderr}")
                results = json.loads(run.stdout)["results"]
        finally:
            # rmdir (not Remove-Item -Recurse, which follows junctions) removes the junction reparse points
            # without touching their targets. base has no spaces, so no quoting is needed.
            self._ssh("cmd", "/c", f"rmdir /s /q {base}")

        finals = {r["path"]: r["final"] for r in results}
        errs = {r["path"]: r["error"] for r in results}

        # Real (non-reparse) paths resolve, returning the Win32 namespace form; prove normalize_final_path
        # turns the REAL GetFinalPathNameByHandleW output into the drive-form path the fence accepts.
        self.assertIsNotNone(finals.get(root), f"root did not resolve: {results!r}")
        self.assertTrue(finals[root].startswith("\\\\?\\"),
                        f"expected the real \\?\\ form from GetFinalPathNameByHandleW, got {finals[root]!r}")
        norm_root = wc.normalize_final_path(finals[root])
        self.assertRegex(norm_root, r"^[A-Za-z]:\\", f"normalize_final_path gave a non-drive path: {norm_root!r}")
        self.assertIsNotNone(finals.get(legit), f"the in-root file did not resolve: {results!r}")
        self.assertTrue(wc.normalize_final_path(finals[legit]).lower().startswith(norm_root.lower()),
                        f"the in-root file resolved outside root: {finals[legit]!r}")

        # KEY FINDING (bead d1d): an agent-created junction is an "untrusted mount point". Modern Windows
        # refuses to TRAVERSE it — CreateFileW that follows the link (no FILE_FLAG_OPEN_REPARSE_POINT) fails
        # with GetLastError 448 (ERROR_CANT_ACCESS_FILE / "untrusted mount point"). So the resolver cannot
        # follow ANY planted junction and denies at open time — a stronger guarantee than a name check: a
        # junction can never be followed out of (or within) the root. Holds for the escape, an in-root
        # junction, and a broken one alike.
        for jp, what in ((j_escape, "escape -> C:\\Windows"), (j_inroot, "in-root -> root\\sub"),
                         (j_bad, "broken -> missing target")):
            self.assertIsNone(finals.get(jp), f"junction ({what}) was unexpectedly followed: {finals.get(jp)!r}")
            self.assertIn("448", errs.get(jp) or "",
                          f"junction ({what}) should fail with the untrusted-mount-point error 448: {errs.get(jp)!r}")

        resolver = _LiveResolver(finals)

        # ALLOW: a genuine in-root file (no reparse point).
        rp = wc.resolved_within(root, legit, resolver)
        self.assertTrue(rp.canonical.lower().startswith(norm_root.lower()),
                        f"legit file resolved outside root: {rp.canonical!r} vs {norm_root!r}")

        # DENY (fail closed): every agent-created junction — the escape, the in-root one, and the broken one.
        # A lexical-only resolver would wrongly ALLOW the in-root and escaping junctions; the real resolver
        # denies all three because it cannot follow an untrusted mount point.
        for jp, what in ((j_escape, "escape"), (j_inroot, "in-root"), (j_bad, "broken")):
            with self.assertRaises(wc.ContainError, msg=f"junction ({what}) must be denied"):
                wc.resolved_within(root, jp, resolver)


if __name__ == "__main__":
    live_gate.main()
