#!/usr/bin/env python3
"""WS1 build-driver hermetic selftest — pins build-on-windows.sh against RoseCat's defb5a2 findings.

Drives tests/windows/build-on-windows.sh with fake `git`/`ssh`/`scp`/`timeout` on PATH (no Windows host,
no network, no display). Asserts the hardened contract:

  * clean/EXACT source (1): stages `git archive` of a verified SHA into a FRESH per-SHA run dir; never a
    working-tree `tar -c`; a bad commit fails closed.
  * no remote injection (2): `step`/`mode` validated against strict grammars; the build is sent as a base64
    `-EncodedCommand`, so an injected cmd metacharacter in a path never appears unencoded in the ssh argv.
  * fail closed (3): tar/archive, stage ssh, build, and fetch failures each exit nonzero and are named.
  * deadlines (4): stage/build/fetch each run under `timeout` with the configured durations.
  * atomic + validated fetch (6): the exe lands via a `.part` file, is validated as a PE, then renamed;
    a failed or non-PE fetch leaves no artifact; provenance (`<out>.sha`) records the source commit.
  * display scrub (0.3): no DISPLAY/WAYLAND/XAUTHORITY reaches any child that talks to the guest.

Point ZB_SELFTEST_SCRIPT at an alternate script to prove these red against the pre-fix version.
Run alone:  python3 -I tests/windows/build_on_windows_selftest.py -v
"""
import base64
import os
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = os.environ.get("ZB_SELFTEST_SCRIPT", str(REPO / "tests" / "windows" / "build-on-windows.sh"))
_BASE_PATH = "/usr/bin:/bin"

FAKE_SHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

_GIT_STUB = r"""
[ -n "${ZB_SELFTEST_GIT_LOG:-}" ] && printf '%s\n' "$*" >> "$ZB_SELFTEST_GIT_LOG"
if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then echo "$ZB_SELFTEST_ROOT"; exit 0; fi
if [ "$1" = "rev-parse" ] && [ "$2" = "--verify" ]; then
  case "$3" in BADCOMMIT*) exit 1 ;; *) echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; exit 0 ;; esac
fi
if [ "$1" = "archive" ]; then
  [ -n "${ZB_SELFTEST_ARCHIVE_FAIL:-}" ] && exit 7
  printf 'FAKE-TAR-STREAM'; exit 0
fi
# the pre-fix script may call other git subcommands; succeed quietly
exit 0
"""

_TIMEOUT_STUB = r"""
dur="$1"; shift
[ -n "${ZB_SELFTEST_TIMEOUT_LOG:-}" ] && printf '%s\n' "$dur" >> "$ZB_SELFTEST_TIMEOUT_LOG"
exec "$@"
"""

_SSH_STUB = r"""
if [ -n "${ZB_SELFTEST_SSH_LOG:-}" ]; then
  printf 'ARGV: %s\n' "$*" >> "$ZB_SELFTEST_SSH_LOG"
  printf 'ENV DISPLAY=[%s] WAYLAND=[%s] XAUTH=[%s]\n' "${DISPLAY:-}" "${WAYLAND_DISPLAY:-}" "${XAUTHORITY:-}" >> "$ZB_SELFTEST_SSH_LOG"
fi
argv="$*"
case "$argv" in
  *tar\ -x*)                       # STAGE: consume the archive stream from stdin
    cat >/dev/null 2>&1
    [ -n "${ZB_SELFTEST_STAGE_FAIL:-}" ] && exit 11
    exit 0 ;;
  *EncodedCommand*)                # BUILD (hardened path)
    [ -n "${ZB_SELFTEST_BUILD_FAIL:-}" ] && exit 12
    exit 0 ;;
  *zig*build*)                     # BUILD (pre-fix path: raw interpolated command)
    [ -n "${ZB_SELFTEST_BUILD_FAIL:-}" ] && exit 12
    exit 0 ;;
esac
cat >/dev/null 2>&1
exit 0
"""

_SCP_STUB = r"""
if [ -n "${ZB_SELFTEST_SCP_LOG:-}" ]; then
  printf 'ARGV: %s\n' "$*" >> "$ZB_SELFTEST_SCP_LOG"
  printf 'ENV DISPLAY=[%s] WAYLAND=[%s] XAUTH=[%s]\n' "${DISPLAY:-}" "${WAYLAND_DISPLAY:-}" "${XAUTHORITY:-}" >> "$ZB_SELFTEST_SCP_LOG"
fi
[ -n "${ZB_SELFTEST_FETCH_FAIL:-}" ] && exit 13
dest="${@: -1}"
if [ -n "${ZB_SELFTEST_FETCH_NOTPE:-}" ]; then printf 'XXnotpe' > "$dest"; else printf 'MZfakepe' > "$dest"; fi
exit 0
"""


def _write(path, body):
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(0o755)


def _fakes(bindir):
    _write(bindir / "git", _GIT_STUB)
    _write(bindir / "ssh", _SSH_STUB)
    _write(bindir / "scp", _SCP_STUB)
    _write(bindir / "timeout", _TIMEOUT_STUB)
    return str(bindir)


class _Case(unittest.TestCase):
    def _run(self, td, extra=None, args=None, unset=None):
        bindir = td / "bin"; bindir.mkdir(exist_ok=True)
        root = td / "root"; root.mkdir(exist_ok=True)
        out = td / "out" / "zigBrowser.exe"
        env = {
            "PATH": _fakes(bindir) + os.pathsep + _BASE_PATH,
            "HOME": str(td / "home"),
            "ZB_SELFTEST_ROOT": str(root),
            "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222", "ZB_WIN11_USER": "zbtext",
            "ZB_WIN_KEY": str(td / "key"), "ZB_WIN_KNOWN_HOSTS": str(td / "kh"),
            "ZB_WEBVIEW2_INCLUDE": r"C:\wv2\include", "ZB_WEBVIEW2_LIB": r"C:\wv2\lib\x64",
            "ZB_ZIG": r"C:\tools\zig.exe",
            "ZB_WIN_EXE": str(out),
            "ZB_SELFTEST_SSH_LOG": str(td / "ssh.log"),
            "ZB_SELFTEST_SCP_LOG": str(td / "scp.log"),
            "ZB_SELFTEST_GIT_LOG": str(td / "git.log"),
            "ZB_SELFTEST_TIMEOUT_LOG": str(td / "timeout.log"),
            # a real display in the parent, to prove it is scrubbed from children
            "DISPLAY": ":99", "WAYLAND_DISPLAY": "wayland-9", "XAUTHORITY": "/tmp/parent.Xauth",
        }
        (td / "home").mkdir(exist_ok=True)
        (td / "key").write_text("x"); (td / "kh").write_text("#")
        if extra:
            env.update(extra)
        for k in (unset or []):
            env.pop(k, None)
        cmd = ["bash", SCRIPT] + (args or [])
        proc = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=90)
        proc.out_path = out
        proc.td = td
        return proc

    def _read(self, p):
        try:
            return (p).read_text()
        except Exception:
            return ""

    def _decoded_build(self, td):
        """Decode the base64 UTF-16LE -EncodedCommand the build ssh call carried, from ssh.log."""
        for line in self._read(td / "ssh.log").splitlines():
            if "ARGV:" in line and "-EncodedCommand" in line:
                tok = line.split("-EncodedCommand", 1)[1].split()[0]
                try:
                    return base64.b64decode(tok).decode("utf-16-le")
                except Exception:
                    return ""
        return ""

    def _fail_closed(self, proc, needle):
        detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        self.assertNotEqual(proc.returncode, 0, "must fail closed" + detail)
        self.assertIn(needle, proc.stdout + proc.stderr, f"expected {needle!r}" + detail)


class HappyPath(_Case):
    def test_builds_and_fetches_validated_artifact_with_provenance(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td)
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertEqual(proc.returncode, 0, "happy path must succeed" + detail)
            self.assertTrue(proc.out_path.exists(), "artifact must be published" + detail)
            self.assertEqual(proc.out_path.read_bytes()[:2], b"MZ", "artifact must be the fetched PE")
            self.assertEqual((proc.out_path.parent / "zigBrowser.exe.sha").read_text().strip(), FAKE_SHA,
                             "provenance .sha must record the source commit")


class MachineWideDefaults(_Case):
    """bead zigBrowser-4dr, option B: zig 0.16.0 in C:\\tools\\zig and the WebView2 SDK nuget in
    C:\\tools\\webview2 are installed machine-wide (readable by all users), so the build driver must
    default to those paths when ZB_ZIG / ZB_WEBVIEW2_INCLUDE / ZB_WEBVIEW2_LIB are not set. The paths
    land inside the base64 -EncodedCommand, so we decode it rather than scan the raw argv."""

    def test_defaults_to_c_tools_layout_when_unset(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, unset=["ZB_ZIG", "ZB_WEBVIEW2_INCLUDE", "ZB_WEBVIEW2_LIB"])
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertEqual(proc.returncode, 0, "must build with the machine-wide C:\\tools defaults" + detail)
            cmd = self._decoded_build(td)
            self.assertIn(r"C:\tools\zig\zig.exe", cmd, "zig must default to C:\\tools\\zig\\zig.exe" + detail)
            self.assertIn(r"C:\tools\webview2\build\native\include", cmd,
                          "WebView2 include must default to the nuget's build\\native\\include" + detail)
            self.assertIn(r"C:\tools\webview2\build\native\x64", cmd,
                          "WebView2 x64 lib must default to the nuget's build\\native\\x64" + detail)


class Injection(_Case):
    def test_bad_commit_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run(pathlib.Path(t), {"ZB_BUILD_COMMIT": "BADCOMMIT"})
            self._fail_closed(proc, "cannot resolve commit")

    def test_hostile_step_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run(pathlib.Path(t), args=["; rm -rf /"])
            self._fail_closed(proc, "invalid build step")

    def test_hostile_mode_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run(pathlib.Path(t), {"ZB_BUILD_MODE": "Release; calc"})
            self._fail_closed(proc, "invalid -Doptimize")

    def test_metachar_path_is_encoded_not_injected(self):
        """A WebView2 path containing cmd metacharacters must be base64-encoded, never raw in the ssh argv."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, {"ZB_WEBVIEW2_INCLUDE": r'C:\x" & calc.exe & "'})
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertEqual(proc.returncode, 0, "metachar path should still build via EncodedCommand" + detail)
            ssh_log = self._read(td / "ssh.log")
            self.assertIn("-EncodedCommand", ssh_log, "build must use -EncodedCommand")
            self.assertNotIn("& calc.exe &", ssh_log, "injected metacharacters must not reach the ssh argv raw")


class FailClosed(_Case):
    def test_archive_failure(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run(pathlib.Path(t), {"ZB_SELFTEST_ARCHIVE_FAIL": "1"})
            self._fail_closed(proc, "git archive failed")

    def test_stage_failure(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run(pathlib.Path(t), {"ZB_SELFTEST_STAGE_FAIL": "1"})
            self._fail_closed(proc, "stage failed")

    def test_build_failure(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run(pathlib.Path(t), {"ZB_SELFTEST_BUILD_FAIL": "1"})
            self._fail_closed(proc, "build failed")

    def test_fetch_failure_leaves_no_artifact(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run(pathlib.Path(t), {"ZB_SELFTEST_FETCH_FAIL": "1"})
            self._fail_closed(proc, "fetch failed")
            self.assertFalse(proc.out_path.exists(), "a failed fetch must leave no artifact")

    def test_non_pe_artifact_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run(pathlib.Path(t), {"ZB_SELFTEST_FETCH_NOTPE": "1"})
            self._fail_closed(proc, "not a PE")
            self.assertFalse(proc.out_path.exists(), "a non-PE fetch must not be published")
            self.assertFalse((proc.out_path.parent / "zigBrowser.exe.part").exists(), "no .part left behind")


class CleanSource(_Case):
    def test_uses_git_archive_of_verified_sha_into_fresh_rundir(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td)
            git_log = self._read(td / "git.log")
            ssh_log = self._read(td / "ssh.log")
            self.assertIn("archive", git_log, "must stage via git archive (clean, tracked-only)")
            self.assertIn(FAKE_SHA, git_log, "git archive must be of the verified SHA")
            self.assertIn(f"run-{FAKE_SHA}", ssh_log, "must stage into a per-SHA fresh run dir")
            self.assertIn("rmdir", ssh_log, "the per-SHA run dir must be re-created fresh each run")
            self.assertNotIn("tar -c", ssh_log + git_log, "must NOT tar the working tree")

    def test_archive_excludes_symlinked_thoughts_tree(self):
        """thoughts/ holds git symlinks (global/maceo/shared); Windows tar cannot create them and the stage
        dies with 'Invalid argument' (observed on win11-m8). The clean stage must exclude that tree."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            self._run(td)
            git_log = self._read(td / "git.log")
            self.assertRegex(git_log, r"archive[^\n]*exclude\)thoughts",
                             "git archive must exclude the symlinked thoughts/ tree Windows tar cannot create")


class Deadlines(_Case):
    def test_stage_build_fetch_each_bounded_by_timeout(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td)
            durs = [l.strip() for l in self._read(td / "timeout.log").splitlines() if l.strip()]
            self.assertEqual(len(durs), 3, f"stage+build+fetch must each be under timeout; got {durs}")
            self.assertEqual(durs, ["300", "1800", "300"], f"default deadlines wrong: {durs}")


class DisplayScrub(_Case):
    def test_no_display_reaches_guest_children(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td)
            logs = self._read(td / "ssh.log") + self._read(td / "scp.log")
            self.assertIn("ENV DISPLAY=[]", logs, "DISPLAY must be scrubbed from every guest child")
            self.assertNotIn("DISPLAY=[:99]", logs, "the parent DISPLAY must never reach a child")
            self.assertNotIn("WAYLAND=[wayland-9]", logs)
            self.assertNotIn("XAUTH=[/tmp/parent.Xauth]", logs)


class SshHygiene(_Case):
    def test_every_ssh_and_scp_passes_batchmode(self):
        # Team rule: a refused key must fail at once, never open a GUI password prompt on
        # the user's DISPLAY :0. Every real ssh/scp build-on-windows.sh runs must carry
        # -o BatchMode=yes. (The fake ssh/scp stubs log their argv to ssh.log/scp.log.)
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("BatchMode=yes", self._read(td / "ssh.log"),
                          "build-on-windows.sh ssh must pass -o BatchMode=yes")
            self.assertIn("BatchMode=yes", self._read(td / "scp.log"),
                          "build-on-windows.sh scp must pass -o BatchMode=yes")


if __name__ == "__main__":
    unittest.main()
