#!/usr/bin/env python3
r"""WS1.2 m8 run driver selftest (NavyCanyon f52ef80): tests/windows/m8_run.py, hostless.

f52ef80 blocked the m8 Win11 request because the build folder %USERPROFILE%\zb\build\run-<full sha> was left to a
hand deletion, and nothing checked the published exe against the commit. The reviewed caller m8_run.py:
  1. requires the Win11 configuration (host, port, user, key, known_hosts, marker; no default key) and removes
     every inherited ZB_WIN10_*, legacy ZB_WIN_KEY / ZB_WIN_KNOWN_HOSTS and ZB_HOST_LIVE from its children;
  2. checks the host identity marker, then takes the WebView2 process census BEFORE the build;
  3. builds ZB_BUILD_COMMIT (resolved to the full sha) with tests/windows/build-on-windows.sh (no step);
  4. resolves the published ZB_WIN_EXE once and requires its sibling `.sha` to equal the full commit; prints
     `EXE\t<resolved path>\tsha256=<hex>\tcommit=<sha>`;
  5. runs tests/windows/m8_live_test.py with ZB_WIN_EXE = that resolved path;
  6. always removes %USERPROFILE%\zb\build\run-<sha> through webview2_cleanup.remove_after_webview2 with the
     before census (the only deletion it makes), and a failed cleanup fails the run.
Exit: the m8 test's exit code when the provenance and the cleanup hold, else 1.

Drives the REAL m8_run.py and webview2_cleanup.py, copied into a temp tree next to a fake build-on-windows.sh and a
fake m8_live_test.py, with a recording fake ssh/git first on PATH. Every fake host is TEST-NET with keys that do not
exist (fake_transport.problem checks the env and every logged ssh argv), and every driver run is inside
`unshare --user --map-current-user --net`.

Run alone:  python3 -I tests/windows/m8_run_selftest.py -v
"""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from fake_transport import FAKE_WIN10_HOST, FAKE_WIN11_HOST, problem as transport_problem  # noqa: E402

NETNS = ["unshare", "--user", "--map-current-user", "--net"]
SHA = "c0ffee" + "0" * 34
MARKER = "zb-fake-marker"
BUILD_DIR = rf"%USERPROFILE%\zb\build\run-{SHA}"
STRIPPED = ("ZB_WIN10_HOST", "ZB_WIN10_PORT", "ZB_WIN10_USER", "ZB_WIN10_KEY", "ZB_WIN10_KNOWN_HOSTS",
            "ZB_WIN10_MARKER", "ZB_WIN10_PYTHON", "ZB_WIN10_LISTEN", "ZB_WIN_KEY", "ZB_WIN_KNOWN_HOSTS",
            "ZB_HOST_LIVE")

_FAKE_SSH = r"""#!/usr/bin/env bash
printf 'SSH %s\n' "$*" >> "$ZB_FAKE_LOG"
cmd="${@: -1}"
case "$cmd" in
  *.gate-identity*) printf '%s\r\n' "${ZB_FAKE_SEEN_MARKER:-$ZB_WIN11_MARKER}"; exit 0 ;;
  *Get-Process*) [ -n "${ZB_FAKE_CENSUS_FAIL:-}" ] && { echo "denied" >&2; exit 1; }; printf 'END\r\n'; exit 0 ;;
  *Get-Item*) printf 'DIR\r\n'; exit 0 ;;
  rmdir*) exit 0 ;;
  if\ exist*) if [ -n "${ZB_FAKE_RMDIR_LEFT:-}" ]; then printf 'LEFT\r\n'; else printf 'GONE\r\n'; fi; exit 0 ;;
esac
exit 0
"""
_FAKE_GIT = r"""#!/usr/bin/env bash
if [ "$1" = "rev-parse" ]; then echo "$ZB_FAKE_SHA"; exit 0; fi
exit 0
"""
# the fake driver records its argv and the selectors it inherited, then publishes <dir>/g-1/<name> + .sha
_FAKE_BUILD = r"""#!/usr/bin/env bash
printf 'BUILD argv=[%s]\n' "$*" >> "$ZB_FAKE_LOG"
env | grep -E '^ZB_(WIN10_|WIN_KEY|WIN_KNOWN_HOSTS|HOST_LIVE)' | sed 's/^/BUILD-ENV /' >> "$ZB_FAKE_LOG"
[ "${ZB_FAKE_BUILD:-ok}" = fail ] && { echo "zig build failed" >&2; exit 12; }
out="$ZB_WIN_EXE"; dir=$(dirname "$out"); root=$(dirname "$dir"); name=$(basename "$out")
mkdir -p "$root/g-1"; printf 'MZfake-%s' "$ZB_BUILD_COMMIT" > "$root/g-1/$name"
case "${ZB_FAKE_BUILD:-ok}" in
  ok) printf '%s\n' "$ZB_FAKE_SHA" > "$root/g-1/$name.sha" ;;
  badsha) printf '%s\n' "deadbeef$(printf '%.0s0' $(seq 1 32))" > "$root/g-1/$name.sha" ;;
  nosha) : ;;
esac
ln -sfn g-1 "$dir"
exit 0
"""
_FAKE_M8 = r"""import json, os, sys
keep = {k: v for k, v in os.environ.items() if k.startswith("ZB_")}
exe = os.environ.get("ZB_WIN_EXE", "")
with open(os.environ["ZB_FAKE_M8_LOG"], "w") as f:
    json.dump({"env": keep, "exe_exists": os.path.isfile(exe), "argv": sys.argv[1:]}, f)
with open(os.environ["ZB_FAKE_LOG"], "a") as f:
    f.write("M8 ran\n")
rc = int(os.environ.get("ZB_FAKE_M8_RC", "1"))
print("RESULT\twin11\tm8_render_test\tPASS\tASSERTS 3")
print("ASSERTS 3")
if rc == 1:
    print("INCOMPLETE: both hosts are required", file=sys.stderr)
sys.exit(rc)
"""


def census_end(lines):
    """Index just past the build (or the m8 run): where the post-run cleanup starts."""
    marks = [i for i, l in enumerate(lines) if l.startswith(("BUILD argv", "M8 ran"))]
    return (marks[-1] + 1) if marks else 0


class M8RunDriver(unittest.TestCase):
    def _run(self, **over):
        t = tempfile.mkdtemp(prefix="zb-m8run-")
        self.addCleanup(shutil.rmtree, t, True)
        td = pathlib.Path(t)
        root = td / "repo"; (root / "tests" / "windows").mkdir(parents=True)
        win = root / "tests" / "windows"
        for name in ("m8_run.py", "webview2_cleanup.py"):
            src = HERE / name
            if src.exists():
                shutil.copy2(src, win / name)
        (win / "build-on-windows.sh").write_text(_FAKE_BUILD); (win / "build-on-windows.sh").chmod(0o755)
        (win / "m8_live_test.py").write_text(_FAKE_M8)
        bindir = td / "bin"; bindir.mkdir()
        for name, body in (("ssh", _FAKE_SSH), ("git", _FAKE_GIT)):
            (bindir / name).write_text(body); (bindir / name).chmod(0o755)
        log = td / "calls.log"; log.write_text("")
        m8log = td / "m8.json"
        env = {
            "PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td / "home"), "TMPDIR": str(td),
            "ZB_WIN_GATE": "1",
            "ZB_WIN11_HOST": FAKE_WIN11_HOST, "ZB_WIN11_PORT": "2222", "ZB_WIN11_USER": "zbtext",
            "ZB_WIN11_KEY": str(td / "no-such-key"), "ZB_WIN11_KNOWN_HOSTS": str(td / "no-such-kh"),
            "ZB_WIN11_MARKER": MARKER, "ZB_BUILD_COMMIT": SHA, "ZB_BUILD_MODE": "ReleaseSafe",
            "ZB_WIN_EXE": str(td / "out" / "current" / "zigBrowser.exe"),
            # inherited selectors the driver must keep from every child
            "ZB_WIN10_HOST": FAKE_WIN10_HOST, "ZB_WIN10_PORT": "22", "ZB_WIN10_USER": "zbtest",
            "ZB_WIN10_KEY": str(td / "no-such-k10"), "ZB_WIN10_KNOWN_HOSTS": str(td / "no-such-kh10"),
            "ZB_WIN10_MARKER": "m10", "ZB_WIN10_PYTHON": r"C:\py\python.exe", "ZB_WIN10_LISTEN": FAKE_WIN10_HOST,
            "ZB_WIN_KEY": str(td / "no-such-legacy"), "ZB_WIN_KNOWN_HOSTS": str(td / "no-such-legacy-kh"),
            "ZB_HOST_LIVE": "1",
            "ZB_FAKE_LOG": str(log), "ZB_FAKE_M8_LOG": str(m8log), "ZB_FAKE_SHA": SHA,
        }
        (td / "home").mkdir()
        env.update(over)
        env = {k: v for k, v in env.items() if v is not None}
        self.assertIsNone(transport_problem(env, []), "fake m8 run is not fail-safe")
        proc = subprocess.run([*NETNS, "python3", "-I", str(win / "m8_run.py")], cwd=root, env=env,
                              capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
        lines = log.read_text().splitlines()
        ssh = [l[4:].split() for l in lines if l.startswith("SSH ")]
        self.assertIsNone(transport_problem(env, ssh), "fake m8 run is not fail-safe")
        m8 = json.loads(m8log.read_text()) if m8log.exists() else None
        detail = (f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls:\n"
                  + "\n".join(lines))
        self.assertNotIn("unshare: ", proc.stderr, "the network namespace must start" + detail)
        self.assertNotIn("can't open file", proc.stderr, "tests/windows/m8_run.py must exist" + detail)
        return proc, lines, m8, td, detail

    @staticmethod
    def _rmdirs(lines):
        return [l for l in lines if l.startswith("SSH ") and (" rmdir " in l or " del " in l.lower()
                                                              or "Remove-Item" in l)]

    def _cleaned_once(self, lines, detail):
        rm = self._rmdirs(lines)
        self.assertEqual(len(rm), 1, "exactly one deletion, through the shared helper" + detail)
        self.assertIn(f'rmdir /s /q "{BUILD_DIR}"', rm[0], "it removes the build folder of the full sha" + detail)
        # the shared helper's own sequence: a census after the run, the folder probe, the one rmdir, the absence
        # check (a hand `rmdir` has none of these around it)
        at = lines.index(rm[0])
        self.assertTrue(any("Get-Process" in l for l in lines[census_end(lines):at]),
                        "the helper re-takes the census before deleting" + detail)
        self.assertIn("Get-Item", lines[at - 1], "the helper probes the folder kind just before the rmdir" + detail)
        self.assertTrue(at + 1 < len(lines) and "if exist" in lines[at + 1], "then checks it is gone" + detail)

    def test_happy_run_checks_provenance_runs_m8_on_the_resolved_exe_and_cleans_the_build_folder(self):
        proc, lines, m8, td, detail = self._run()
        self.assertEqual(proc.returncode, 1, "the m8 exit code passes through (Win11 only: INCOMPLETE)" + detail)
        resolved = os.path.realpath(td / "out" / "current" / "zigBrowser.exe")
        digest = hashlib.sha256(pathlib.Path(resolved).read_bytes()).hexdigest()
        self.assertIn(f"EXE\t{resolved}\tsha256={digest}\tcommit={SHA}", proc.stdout, detail)
        self.assertIsNotNone(m8, "the m8 test ran" + detail)
        self.assertEqual(m8["env"].get("ZB_WIN_EXE"), resolved, "m8 tests the resolved, checked exe" + detail)
        census = next(i for i, l in enumerate(lines) if "Get-Process" in l)
        build = next(i for i, l in enumerate(lines) if l.startswith("BUILD argv"))
        self.assertLess(census, build, "the census is taken before the build" + detail)
        self.assertIn("BUILD argv=[]", lines, "the build runs with no step argument" + detail)
        self._cleaned_once(lines, detail)

    def test_m8_pass_and_clean_cleanup_pass(self):
        proc, lines, _, _, detail = self._run(ZB_FAKE_M8_RC="0")
        self.assertEqual(proc.returncode, 0, detail)
        self._cleaned_once(lines, detail)

    def test_children_never_see_win10_legacy_or_live_selectors(self):
        _, lines, m8, _, detail = self._run()
        self.assertFalse([l for l in lines if l.startswith("BUILD-ENV ")], "the build inherited selectors" + detail)
        self.assertIsNotNone(m8, detail)
        leaked = sorted(k for k in m8["env"] if k in STRIPPED)
        self.assertEqual(leaked, [], "the m8 test inherited selectors" + detail)

    def test_a_published_sha_that_is_not_the_commit_fails_before_testing(self):
        for mode in ("badsha", "nosha"):
            with self.subTest(build=mode):
                proc, lines, m8, _, detail = self._run(ZB_FAKE_BUILD=mode)
                self.assertEqual(proc.returncode, 1, detail)
                self.assertIn("provenance", proc.stderr, detail)
                self.assertIsNone(m8, "no test runs on an unproven exe" + detail)
                self._cleaned_once(lines, detail)

    def test_a_failed_build_runs_no_test_and_still_cleans(self):
        proc, lines, m8, _, detail = self._run(ZB_FAKE_BUILD="fail")
        self.assertEqual(proc.returncode, 1, detail)
        self.assertIsNone(m8, detail)
        self._cleaned_once(lines, detail)

    def test_a_census_that_cannot_be_read_builds_nothing(self):
        proc, lines, m8, _, detail = self._run(ZB_FAKE_CENSUS_FAIL="1")
        self.assertEqual(proc.returncode, 1, detail)
        self.assertFalse([l for l in lines if l.startswith("BUILD")], "no build without a before census" + detail)
        self.assertEqual(self._rmdirs(lines), [], detail)
        self.assertIsNone(m8, detail)

    def test_a_failed_cleanup_fails_a_passing_run(self):
        proc, lines, _, _, detail = self._run(ZB_FAKE_M8_RC="0", ZB_FAKE_RMDIR_LEFT="1")
        self.assertEqual(proc.returncode, 1, detail)
        self.assertIn("cleanup failed", proc.stderr, detail)

    def test_wrong_host_marker_builds_nothing(self):
        proc, lines, m8, _, detail = self._run(ZB_FAKE_SEEN_MARKER="someone-else")
        self.assertEqual(proc.returncode, 1, detail)
        self.assertFalse([l for l in lines if l.startswith("BUILD") or "Get-Process" in l], detail)
        self.assertIsNone(m8, detail)

    def test_incomplete_win11_configuration_contacts_nothing(self):
        for missing in ("ZB_WIN11_HOST", "ZB_WIN11_KEY", "ZB_WIN11_KNOWN_HOSTS", "ZB_WIN11_MARKER",
                        "ZB_BUILD_COMMIT"):
            with self.subTest(missing=missing):
                proc, lines, m8, _, detail = self._run(**{missing: None})
                self.assertEqual(proc.returncode, 1, "a missing precondition fails under the gate" + detail)
                self.assertEqual(lines, [], "nothing is contacted or built" + detail)


if __name__ == "__main__":
    unittest.main()
