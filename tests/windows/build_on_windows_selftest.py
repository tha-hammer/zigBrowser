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
import shutil
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

# A fake iconv that fails on demand (to exercise the CHECKED build-command encode), else passes through.
_ICONV_FAKE = r"""
[ -n "${ZB_SELFTEST_ICONV_FAIL:-}" ] && exit 5
exec /usr/bin/iconv "$@"
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
    _write(bindir / "iconv", _ICONV_FAKE)
    return str(bindir)


class _Case(unittest.TestCase):
    def _run(self, td, extra=None, args=None, unset=None, pre=None):
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
        if pre:
            pre(td, out)
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

    def _stage_cmd(self, td):
        """The ssh ARGV line that carries the remote staging command (the one running tar -x)."""
        for ln in self._read(td / "ssh.log").splitlines():
            if ln.startswith("ARGV:") and "tar -x" in ln:
                return ln
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


# --- BatchMode oracle: every ssh/scp invocation must have EFFECTIVE BatchMode=yes ----------
# Each 'ARGV: ...' line a stub writes is one invocation. OpenSSH resolves -o options
# FIRST-occurrence-wins (case-insensitive), so we never hand-parse precedence: we hand each
# invocation's -o options to `ssh -G` itself and read the effective BatchMode it computes.
def _ssh_invocations(log_text):
    return [ln[len("ARGV:"):].split() for ln in log_text.splitlines() if ln.startswith("ARGV:")]


def _o_options(tokens):
    """The -o options from one invocation, in order (both `-o Name=Val` and `-oName=Val`)."""
    opts = []
    i = 0
    while i < len(tokens):
        if tokens[i] == "-o" and i + 1 < len(tokens):
            opts += ["-o", tokens[i + 1]]; i += 2
        elif tokens[i].startswith("-o") and len(tokens[i]) > 2:
            opts.append(tokens[i]); i += 1
        else:
            i += 1
    return opts


def _batchmode_is_on(o_options):
    """OpenSSH's EFFECTIVE BatchMode for these -o options, resolved by `ssh -G` itself
    (first-occurrence-wins, case-insensitive) — authoritative, never a hand parser."""
    ssh = shutil.which("ssh") or "/usr/bin/ssh"
    proc = subprocess.run([ssh, "-G", "-F", "/dev/null", *o_options, "zb-batchmode-probe.invalid"],
                          capture_output=True, text=True, timeout=30)
    for line in proc.stdout.splitlines():
        parts = line.split(None, 1)
        if parts and parts[0].lower() == "batchmode":
            return (parts[1].strip().lower() if len(parts) > 1 else "") in ("yes", "true", "on")
    return False


def _batchmode_violations(log_text):
    invs = _ssh_invocations(log_text)
    return invs, [t for t in invs if not _batchmode_is_on(_o_options(t))]


class SshHygiene(_Case):
    def test_every_ssh_and_scp_invocation_has_effective_batchmode_yes(self):
        # Team rule: a refused key must fail at once, never open a GUI password prompt on DISPLAY :0.
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            for name in ("ssh.log", "scp.log"):
                invs, bad = _batchmode_violations(self._read(td / name))
                self.assertTrue(invs, f"build-on-windows.sh ran no {name} invocations to check")
                self.assertEqual(bad, [], f"{name} invocations without effective BatchMode=yes: {bad}")

    def test_oracle_flags_a_call_that_omits_batchmode(self):
        # Failing-first (1): one call keeps BatchMode, another omits it (OpenSSH default is no).
        invs, bad = _batchmode_violations(
            "ARGV: -i k -o BatchMode=yes -p 2222 zbtext@127.0.0.1 cmd\n"
            "ARGV: -i k -o StrictHostKeyChecking=yes -p 2222 zbtext@127.0.0.1 cmd\n")
        self.assertEqual(len(invs), 2)
        self.assertEqual(len(bad), 1, "the invocation without BatchMode must be flagged")

    def test_oracle_flags_batchmode_no_then_yes(self):
        # Failing-first (2): OpenSSH is FIRST-value-wins, so `no` then `yes` is effectively NO.
        invs, bad = _batchmode_violations("ARGV: -i k -o BatchMode=no -o BatchMode=yes host cmd\n")
        self.assertEqual(len(bad), 1, "effective BatchMode=no (first wins) must be flagged")

    def test_oracle_accepts_batchmode_yes_then_no(self):
        # Mirror: `yes` then `no` is effectively YES (first wins) — OpenSSH treats it safe.
        invs, bad = _batchmode_violations("ARGV: -i k -o BatchMode=yes -o BatchMode=no host cmd\n")
        self.assertEqual(bad, [], "effective BatchMode=yes (first wins) must be accepted")


class StagingFailClosed(_Case):
    """RoseCat cf01d66 (a): the remote dir setup must chain rmdir -> mkdir -> cd -> tar fail-closed with
    && , never a maskable bare & that lets a failed mkdir be hidden by tar's exit status."""

    def test_staging_chains_fail_closed_not_masking_amp(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            self._run(td)
            stage = self._stage_cmd(td)
            self.assertTrue(stage, "no staging ssh invocation captured")
            self.assertIn("rmdir", stage, "stage must re-create the per-SHA dir")
            self.assertIn("mkdir", stage, "stage must create the run dir")
            self.assertNotRegex(
                stage, r"(?<!&) & (?!&)",
                "staging must chain rmdir/mkdir/cd/tar fail-closed with && , never a maskable bare &")


class EncodeChecked(_Case):
    """RoseCat cf01d66 (b): if the UTF-16LE/base64 encode of the build command fails (or yields empty),
    the build must NOT be sent and no artifact may be published."""

    def test_encode_failure_fails_closed_and_publishes_nothing(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, {"ZB_SELFTEST_ICONV_FAIL": "1"})
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0, "a failed command-encoding must fail closed" + detail)
            self.assertFalse(proc.out_path.exists(), "a failed encode must publish no artifact" + detail)


class AtomicProvenance(_Case):
    """RoseCat cf01d66 (c): the exe and its provenance manifest publish as an ATOMIC PAIR. If the
    provenance cannot be written, nothing is published (no orphan artifact). Fault: pre-create the
    staging `.part.sha` path as a directory so the provenance write fails before any publish."""

    def test_provenance_write_failure_does_not_publish_exe(self):
        def pre(td, out):
            out.parent.mkdir(parents=True, exist_ok=True)
            (out.parent / (out.name + ".part.sha")).mkdir()  # $part.sha is where provenance is written first
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, pre=pre)
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0, "an unwritable provenance must fail closed" + detail)
            self.assertFalse(proc.out_path.is_file(),
                             "the exe must NOT be published when its provenance cannot be written" + detail)
            self.assertFalse((proc.out_path.parent / "current").exists(),
                             "no 'current' may be published when provenance fails" + detail)


class AtomicPublish(_Case):
    """RoseCat 42c797b: the {exe, provenance} publish must be ATOMIC — an interruption can never leave an
    exe beside the wrong commit SHA. Start with a valid OLD pair, cut the publish just before the atomic
    'current' swap, and require that the surviving readable pair is MATCHED (here: the old pair stands)."""

    OLD_SHA = "0" * 40
    OLD_EXE = b"MZoldpe\n"

    def _place_old_pair(self, out):
        # Mirror the published layout: vers/<old>/{exe,exe.sha}; current -> it; $out/$out.sha symlinks.
        outdir = out.parent; base = out.name
        outdir.mkdir(parents=True, exist_ok=True)
        v = outdir / "vers" / self.OLD_SHA
        v.mkdir(parents=True)
        (v / base).write_bytes(self.OLD_EXE)
        (v / (base + ".sha")).write_text(self.OLD_SHA + "\n")
        (outdir / "current").symlink_to(pathlib.Path("vers") / self.OLD_SHA)
        out.symlink_to(pathlib.Path("current") / base)
        (outdir / (base + ".sha")).symlink_to(pathlib.Path("current") / (base + ".sha"))

    def _read_pair(self, out):
        try:
            exe = out.read_bytes()
        except OSError:
            exe = None
        try:
            sha = (out.parent / (out.name + ".sha")).read_text().strip()
        except OSError:
            sha = None
        return exe, sha

    def test_interrupted_publish_leaves_no_mismatched_pair(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, {"ZB_SELFTEST_CUT_PUBLISH": "1"}, pre=lambda td, out: self._place_old_pair(out))
            exe, sha = self._read_pair(proc.out_path)
            detail = f"\nrc={proc.returncode}\nexe={exe!r}\nsha={sha!r}\n{proc.stdout}\n{proc.stderr}"
            # The readable pair must be MATCHED: either the old pair or the fully-published new pair,
            # never old-exe+new-sha or new-exe+old-sha.
            matched = ((exe == self.OLD_EXE and sha == self.OLD_SHA)
                       or (exe is not None and exe[:2] == b"MZ" and sha == FAKE_SHA))
            self.assertTrue(matched, "interrupted publish left a MISMATCHED exe/SHA pair" + detail)
            # Cut was before the atomic swap, so 'current' never flipped: the OLD pair must stand intact.
            self.assertEqual((exe, sha), (self.OLD_EXE, self.OLD_SHA),
                             "a cut before the current-swap must leave the old complete pair" + detail)


class StagePrepGatesBuild(_Case):
    """RoseCat 42c797b (2): if the staging prep fails, the build invocation must NEVER be reached."""

    def test_stage_failure_never_reaches_build(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, {"ZB_SELFTEST_STAGE_FAIL": "1"})
            self._fail_closed(proc, "stage failed")
            ssh_log = self._read(td / "ssh.log")
            self.assertNotIn("-EncodedCommand", ssh_log,
                             "the build (EncodedCommand ssh) must not run after a staging-prep failure:\n" + ssh_log)
            self.assertFalse(proc.out_path.exists(), "a staging-prep failure must publish no artifact")


if __name__ == "__main__":
    unittest.main()
