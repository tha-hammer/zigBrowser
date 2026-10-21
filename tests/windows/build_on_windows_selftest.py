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
import fcntl
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
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
# TOCTOU probe hook: announce the fetch has started, then wait for a go-signal, so the test can rename/
# symlink-swap a parent WHILE the fetch is paused. The marker dir is an absolute path (cwd-independent).
if [ -n "${ZB_SELFTEST_SCP_PAUSE:-}" ]; then
  : > "$ZB_SELFTEST_SCP_PAUSE/scp_started"
  i=0; while [ ! -e "$ZB_SELFTEST_SCP_PAUSE/scp_go" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i+1)); done
fi
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
        out = td / "out" / "current" / "zigBrowser.exe"   # ZB_WIN_EXE IS the stable .../current/<base> surface
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
        proc.out_path = out                                 # ZB_WIN_EXE == the single consumer surface
        proc.sha_path = out.parent / (out.name + ".sha")    # current/zigBrowser.exe.sha
        proc.outdir = td / "out"                            # publish root (holds gen/, current, .fetch-*.part)
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
            self.assertEqual(list(proc.outdir.glob(".fetch-*.part")), [], "no fetch .part left behind")


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


_OLD_SHA = "a" * 40
_OLD_EXE = b"MZoldpe\n"


def _place_old_generation(out, sha=None):
    # Published layout (no gen/ hop): <outdir>/g-<g>/{base,base.sha} directly in the root; current -> g-<g>.
    # out is the surface <outdir>/current/<base>, so outdir = out.parent.parent. Returns the gen dir name.
    sha = sha or _OLD_SHA
    outdir = out.parent.parent; base = out.name
    outdir.mkdir(parents=True, exist_ok=True)
    gname = "g-%s-oldgen0001" % sha
    g = outdir / gname
    g.mkdir()
    (g / base).write_bytes(_OLD_EXE)
    (g / (base + ".sha")).write_text(sha + "\n")
    (outdir / "current").symlink_to(gname)
    return gname


def _gens_in(outdir):
    return sorted(p.name for p in outdir.iterdir() if p.is_dir() and p.name.startswith("g-"))


def _read_surface(proc):
    try:
        exe = proc.out_path.read_bytes()
    except OSError:
        exe = None
    try:
        sha = proc.sha_path.read_text().strip()
    except OSError:
        sha = None
    return exe, sha


class PublishContract(_Case):
    """ZB_WIN_EXE IS the .../current/<name> surface (old direct-file form rejected); the publish root is
    refused if ANY path component is a symlink; there is no persistent 'gen/' hop (g-* are direct children
    of the pinned cwd) so a mid-fetch 'gen' swap cannot escape; and the .publish.lock leaf is refused if it
    is a symlink. (RoseCat 3da2862 / c09d439 / 175efb8 / 94be4e5.)"""

    def test_old_direct_file_form_is_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, {"ZB_WIN_EXE": str(td / "out" / "zigBrowser.exe")})  # old ambiguous form
            self._fail_closed(proc, "must be a <dir>/current/<name>")
            self.assertFalse((td / "out" / "current").exists(), "the rejected form must publish nothing")

    def test_gen_swapped_to_symlink_during_fetch_cannot_escape(self):
        # RoseCat 94be4e5: the second TOCTOU, one level down. There is no persistent 'gen/' hop anymore —
        # generations are g-* created fresh (mktemp) directly in the pinned cwd. Even if an attacker plants
        # 'out/gen' as a symlink to a real 'outside' dir mid-fetch, the publish must ignore it and land in the
        # pinned cwd; nothing may be written under 'outside'. (A gen/-hop mutant creates outside/g-*.)
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir(); _fakes(bindir)
            (td / "root").mkdir(); (td / "home").mkdir()
            (td / "key").write_text("x"); (td / "kh").write_text("#")
            outdir = td / "out"; outdir.mkdir()
            marker = td / "marker"; marker.mkdir()
            outside = td / "outside"; outside.mkdir()
            env = {
                "PATH": str(bindir) + os.pathsep + _BASE_PATH, "HOME": str(td / "home"),
                "ZB_SELFTEST_ROOT": str(td / "root"),
                "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222", "ZB_WIN11_USER": "zbtext",
                "ZB_WIN_KEY": str(td / "key"), "ZB_WIN_KNOWN_HOSTS": str(td / "kh"),
                "ZB_WEBVIEW2_INCLUDE": r"C:\wv2\include", "ZB_WEBVIEW2_LIB": r"C:\wv2\lib\x64",
                "ZB_ZIG": r"C:\tools\zig.exe",
                "ZB_WIN_EXE": str(outdir / "current" / "zigBrowser.exe"),
                "ZB_SELFTEST_SCP_PAUSE": str(marker),
                "DISPLAY": ":99", "WAYLAND_DISPLAY": "wayland-9", "XAUTHORITY": "/tmp/parent.Xauth",
            }
            p = subprocess.Popen(["bash", SCRIPT], env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
            try:
                started = marker / "scp_started"
                for _ in range(400):
                    if started.exists():
                        break
                    time.sleep(0.05)
                self.assertTrue(started.exists(), "the fetch never started")
                os.symlink(outside, outdir / "gen")   # plant a 'gen' symlink mid-fetch
                (marker / "scp_go").write_text("go")
                out, err = p.communicate(timeout=60)
            finally:
                if p.poll() is None:
                    p.kill(); p.communicate()
            detail = f"\nrc={p.returncode}\nstdout:\n{out}\nstderr:\n{err}"
            self.assertEqual(list(outside.iterdir()), [],
                             "nothing may be published under a planted 'gen' symlink" + detail)
            self.assertTrue((outdir / "current" / "zigBrowser.exe").exists(),
                            "publish must land in the pinned root (g-* direct child)" + detail)

    def test_lock_leaf_symlink_planted_mid_fetch_does_not_truncate(self):
        # RoseCat 705dcf8: the EXACT mid-fetch race. A '.publish.lock' check-then-open is TOCTOU — a symlink
        # planted AFTER the check (while the fetch is paused) would be followed by a later '>' and truncate
        # the target. The fix locks the PINNED DIRECTORY INODE (fd 9 = cwd '.'), never a lock leaf, so a
        # planted '.publish.lock' symlink is never opened and the victim is never truncated.
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir(); _fakes(bindir)
            (td / "root").mkdir(); (td / "home").mkdir()
            (td / "key").write_text("x"); (td / "kh").write_text("#")
            outdir = td / "out"; outdir.mkdir()
            marker = td / "marker"; marker.mkdir()
            victim = td / "victim.txt"; victim.write_text("precious")
            env = {
                "PATH": str(bindir) + os.pathsep + _BASE_PATH, "HOME": str(td / "home"),
                "ZB_SELFTEST_ROOT": str(td / "root"),
                "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222", "ZB_WIN11_USER": "zbtext",
                "ZB_WIN_KEY": str(td / "key"), "ZB_WIN_KNOWN_HOSTS": str(td / "kh"),
                "ZB_WEBVIEW2_INCLUDE": r"C:\wv2\include", "ZB_WEBVIEW2_LIB": r"C:\wv2\lib\x64",
                "ZB_ZIG": r"C:\tools\zig.exe",
                "ZB_WIN_EXE": str(outdir / "current" / "zigBrowser.exe"),
                "ZB_SELFTEST_SCP_PAUSE": str(marker),
                "DISPLAY": ":99", "WAYLAND_DISPLAY": "wayland-9", "XAUTHORITY": "/tmp/parent.Xauth",
            }
            p = subprocess.Popen(["bash", SCRIPT], env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
            try:
                started = marker / "scp_started"
                for _ in range(400):
                    if started.exists():
                        break
                    time.sleep(0.05)
                self.assertTrue(started.exists(), "the fetch never started")
                (outdir / ".publish.lock").symlink_to(victim)   # plant the lock symlink MID-FETCH
                (marker / "scp_go").write_text("go")
                out, err = p.communicate(timeout=60)
            finally:
                if p.poll() is None:
                    p.kill(); p.communicate()
            detail = f"\nrc={p.returncode}\nstdout:\n{out}\nstderr:\n{err}"
            self.assertEqual(victim.read_text(), "precious",
                             "a lock-leaf symlink planted mid-fetch must not be followed/truncated" + detail)
            self.assertTrue((outdir / "current" / "zigBrowser.exe").exists(),
                            "the dir-inode lock lets the publish still succeed" + detail)

    def test_parent_symlink_root_refused_on_publish_no_escape(self):
        # RoseCat c09d439 (1): a symlink in a PARENT of the publish root (not just the leaf gen) must also be
        # refused, so a delete/write can never escape the intended root.
        def pre(td, out):
            outside = td / "outside"; (outside / "gen" / "g-victim").mkdir(parents=True)
            (outside / "gen" / "g-victim" / "keep").write_text("keep")
            (td / "out").symlink_to(outside)              # the publish ROOT itself is a symlink
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, pre=pre)
            self._fail_closed(proc, "symlink component")
            self.assertTrue((td / "outside" / "gen" / "g-victim" / "keep").exists(),
                            "a parent-symlinked publish root must not let a write/delete escape")

    def test_parent_symlink_root_refused_on_gc_no_escape(self):
        def pre(td, out):
            outside = td / "outside"; (outside / "gen" / "g-victim").mkdir(parents=True)
            (outside / "gen" / "g-victim" / "keep").write_text("keep")
            (td / "out").symlink_to(outside)
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, args=["--gc"], pre=pre)
            self._fail_closed(proc, "symlink component")
            self.assertTrue((td / "outside" / "gen" / "g-victim" / "keep").exists(),
                            "GC on a parent-symlinked root must delete nothing outside it")

    def test_parent_swapped_to_symlink_during_fetch_cannot_escape(self):
        # RoseCat 175efb8: the static path check is TOCTOU. Pause the fetch, rename the real root to
        # 'out-held' and replace 'out' with a symlink to 'outside', then resume. Because the publish pins the
        # directory by cd-ing into it and uses relative paths, the publish must land in the pinned real dir
        # (now 'out-held') and NOTHING may be written under the swapped-in 'outside'.
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir()
            _fakes(bindir)
            (td / "root").mkdir(); (td / "home").mkdir()
            (td / "key").write_text("x"); (td / "kh").write_text("#")
            outdir = td / "out"; marker = td / "marker"; marker.mkdir()
            outside = td / "outside"; outside.mkdir()   # a real writable dir the attacker redirects to
            env = {
                "PATH": str(bindir) + os.pathsep + _BASE_PATH, "HOME": str(td / "home"),
                "ZB_SELFTEST_ROOT": str(td / "root"),
                "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222", "ZB_WIN11_USER": "zbtext",
                "ZB_WIN_KEY": str(td / "key"), "ZB_WIN_KNOWN_HOSTS": str(td / "kh"),
                "ZB_WEBVIEW2_INCLUDE": r"C:\wv2\include", "ZB_WEBVIEW2_LIB": r"C:\wv2\lib\x64",
                "ZB_ZIG": r"C:\tools\zig.exe",
                "ZB_WIN_EXE": str(outdir / "current" / "zigBrowser.exe"),
                "ZB_SELFTEST_SCP_PAUSE": str(marker),
                "DISPLAY": ":99", "WAYLAND_DISPLAY": "wayland-9", "XAUTHORITY": "/tmp/parent.Xauth",
            }
            p = subprocess.Popen(["bash", SCRIPT], env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
            try:
                started = marker / "scp_started"
                for _ in range(400):
                    if started.exists():
                        break
                    time.sleep(0.05)
                self.assertTrue(started.exists(), "the fetch never started")
                os.rename(outdir, td / "out-held")           # the pinned real dir is renamed away
                os.symlink(outside, outdir)                  # 'out' now resolves to 'outside'
                (marker / "scp_go").write_text("go")
                out, err = p.communicate(timeout=60)
            finally:
                if p.poll() is None:
                    p.kill(); p.communicate()
            detail = f"\nrc={p.returncode}\nstdout:\n{out}\nstderr:\n{err}"
            self.assertFalse((outside / "current").exists(),
                             "publish escaped to the swapped-in symlink target" + detail)
            self.assertTrue((td / "out-held" / "current" / "zigBrowser.exe").exists(),
                            "publish must land in the pinned original directory" + detail)


class AtomicPublish(_Case):
    """RoseCat 3da2862 (3): a GUARANTEED-fresh (mktemp) generation + an APPEND-ONLY, flock-serialized, single
    'current' swap. An interruption never leaves a mismatched pair, a same-SHA rerun never disturbs the live
    generation, the swap is checked, and two runs make two distinct generations."""

    def test_happy_publish_exposes_matched_pair_through_current(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td)
            exe, sha = _read_surface(proc)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertTrue(exe is not None and exe[:2] == b"MZ" and sha == FAKE_SHA,
                            f"ZB_WIN_EXE (current/<exe>) must be the matched new pair; exe={exe!r} sha={sha!r}")

    def test_cut_before_swap_leaves_old_generation_intact(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, {"ZB_SELFTEST_CUT_PUBLISH": "1"},
                             pre=lambda td, out: _place_old_generation(out))
            exe, sha = _read_surface(proc)
            detail = f"\nrc={proc.returncode}\nexe={exe!r}\nsha={sha!r}\n{proc.stdout}\n{proc.stderr}"
            self.assertEqual((exe, sha), (_OLD_EXE, _OLD_SHA),
                             "a cut before the swap must leave the old generation owning 'current'" + detail)

    def test_same_sha_rerun_cut_does_not_destroy_live_generation(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, {"ZB_SELFTEST_CUT_PUBLISH": "1", "ZB_BUILD_COMMIT": "HEAD"},
                             pre=lambda td, out: _place_old_generation(out, sha=FAKE_SHA))
            exe, sha = _read_surface(proc)
            detail = f"\nrc={proc.returncode}\nexe={exe!r}\nsha={sha!r}\n{proc.stdout}\n{proc.stderr}"
            self.assertEqual((exe, sha), (_OLD_EXE, FAKE_SHA),
                             "a same-SHA rerun that is cut must leave the live generation intact (append-only)" + detail)

    def test_rerun_is_append_only_keeps_old_generation(self):
        # A successful rerun publishes a NEW generation and swaps current to it, but (append-only) must NOT
        # delete the previous generation during publish.
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            old = None
            def pre(td, out):
                nonlocal old
                old = _place_old_generation(out, sha=FAKE_SHA)
            proc = self._run(td, pre=pre)
            exe, sha = _read_surface(proc)
            detail = f"\nrc={proc.returncode}\nexe={exe!r}\nsha={sha!r}\n{proc.stdout}\n{proc.stderr}"
            self.assertEqual(proc.returncode, 0, "the rerun must succeed" + detail)
            self.assertTrue(exe is not None and exe[:2] == b"MZ" and sha == FAKE_SHA,
                            "current must resolve to the matched NEW pair" + detail)
            gens = _gens_in(proc.outdir)
            self.assertIn(old, gens, "publish is append-only: the old generation must still exist" + detail)
            self.assertGreaterEqual(len(gens), 2, "a rerun must leave BOTH generations (append-only)" + detail)

    def test_two_runs_make_distinct_generations(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            self.assertEqual(self._run(td).returncode, 0)
            g1 = set(_gens_in(td / "out"))
            self.assertEqual(self._run(td).returncode, 0)
            g2 = set(_gens_in(td / "out"))
            self.assertTrue(g2 - g1, "the second run must create a fresh, distinct generation (mktemp O_EXCL)")

    def test_fault_at_the_swap_fails_closed(self):
        # The final swap is CHECKED — a failed rename must NOT report success. Natural fault: pre-create
        # 'current' as a non-empty directory so `mv -fT .current.<pid> current` fails.
        def pre(td, out):
            outdir = out.parent.parent; outdir.mkdir(parents=True, exist_ok=True)
            cur = outdir / "current"; cur.mkdir()
            (cur / "blocker").write_text("x")
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            proc = self._run(td, pre=pre)
            detail = f"\nrc={proc.returncode}\n{proc.stdout}\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0,
                                "a failed current-swap must fail closed (unchecked mv would report success)" + detail)

    def test_gc_cannot_interleave_with_a_held_publish_lock(self):
        # RoseCat c09d439 (2): correctness is the LOCK, not a wall-clock grace. A publisher holds
        # .publish.lock from before generation creation through the swap; GC takes the SAME lock, so while a
        # publish is in progress GC must NOT be able to delete an in-flight (non-current) generation — even an
        # old one. Hold the lock, place an OLD non-current generation, run --gc: it must fail closed and
        # delete nothing. (A GC that ignored the lock would reap the old non-current generation.)
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            out = td / "out" / "current" / "zigBrowser.exe"
            outdir = td / "out"; outdir.mkdir(parents=True)
            _place_old_generation(out, sha=FAKE_SHA)                       # a live generation + current
            inflight = outdir / ("g-%s-inflight0" % FAKE_SHA)             # a non-current generation
            inflight.mkdir()
            (inflight / "zigBrowser.exe").write_bytes(b"MZinflight\n")
            old = time.time() - 7200                                       # 2h old, so grace alone would reap it
            os.utime(inflight, (old, old))
            dirfd = os.open(str(outdir), os.O_RDONLY)                       # the lock IS the directory inode
            try:
                fcntl.flock(dirfd, fcntl.LOCK_EX)                          # a publisher holds the dir-inode lock
                proc = self._run(td, {"ZB_GC_LOCK_WAIT": "1"}, args=["--gc"])
                detail = f"\nrc={proc.returncode}\n{proc.stdout}\n{proc.stderr}"
                self.assertNotEqual(proc.returncode, 0,
                                    "GC must fail closed when it cannot take the publish lock" + detail)
                self.assertTrue(inflight.exists(),
                                "GC must not delete an in-flight generation while a publish holds the lock" + detail)
            finally:
                fcntl.flock(dirfd, fcntl.LOCK_UN); os.close(dirfd)


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
