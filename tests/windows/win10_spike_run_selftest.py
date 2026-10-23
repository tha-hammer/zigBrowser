#!/usr/bin/env python3
r"""WS2b.1-W10 copy-to-Win10 spike driver selftest: tests/windows/win10_spike_run.py, hostless.

The Win10 box (zbtest) has no build toolchain, so a Win10 matrix leg builds the spike on the Win11 VM and runs it on
the Win10 box. The driver (the shape of GrayHarbor's m8_run.py and the shared webview2_cleanup):
  1. requires BOTH host configurations (ZB_WIN11_* and ZB_WIN10_* host/port/user/key/known_hosts/marker; no default
     key) and ZB_BUILD_COMMIT, and keeps every ZB_WIN10_*, the legacy ZB_WIN_KEY / ZB_WIN_KNOWN_HOSTS and
     ZB_HOST_LIVE out of the build driver's environment;
  2. checks both identity markers (%USERPROFILE%\zb\.gate-identity), takes the WebView2 process census on both hosts,
     and refuses a Win10 run folder that already exists — all BEFORE the build;
  3. builds the full sha with tests/windows/build-on-windows.sh <build-only step> on Win11, fetches the exe with the
     legacy scp protocol (-O), prints `EXE\t<path>\tsha256=<hex>\tcommit=<sha>`, and removes the Win11 build folder
     %USERPROFILE%\zb\build\run-<sha> through webview2_cleanup.remove_after_webview2 (always, once built);
  4. stages the exe and the spike's input files, taken from the exact commit (`git show <sha>:<path>`), into
     %USERPROFILE%\zb\build\run-<sha> on Win10 (the only folder it writes there), each copy over scp -O;
  5. runs the exe there over ssh, requires exit 0, no FAIL line and an `ok` line for every required row, prints
     `ASSERTS <n>` and `PASS\t<tag>`;
  6. always removes the Win10 run folder through remove_after_webview2 with the Win10 before census, once staging
     began; a failed cleanup on either host fails the run.

Drives the REAL win10_spike_run.py and its entry tests/e2e/win_trusted_input_matrix_w10.py (with the real
win_trusted_input_matrix.REQUIRED, spike_driver, webview2_cleanup and scp_legacy), copied into a temp tree next to a
fake build-on-windows.sh, with recording fake ssh/scp/git first on PATH. Every fake host is TEST-NET with keys that
do not exist (fake_transport.problem checks the env and every logged ssh/scp argv), and every driver run is inside
`unshare --user --map-current-user --net`. No Windows host is ever contacted.

Run alone:  python3 -I tests/windows/win10_spike_run_selftest.py -v
"""
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
from fake_transport import FAKE_WIN10_HOST, FAKE_WIN11_HOST, problem as transport_problem  # noqa: E402

NETNS = ["unshare", "--user", "--map-current-user", "--net"]
SHA = "c0ffee" + "0" * 34
M11, M10 = "zb-fake-marker-11", "zb-fake-marker-10"
WIN_DIR = rf"%USERPROFILE%\zb\build\run-{SHA}"
REL_DIR = f"zb/build/run-{SHA}"
EXE = "ws2b1-input-spike.exe"
STEP = "ws2b1-input-spike-exe-win"
INPUTS = ("tests/fixtures/automation/input.html", "tests/fixtures/automation/scroll.html",
          "src/automation_script/automation.js")
COPIED = ("tests/windows/win10_spike_run.py", "tests/windows/webview2_cleanup.py", "tests/windows/scp_legacy.py",
          "tests/windows/spike_driver.py", "tests/e2e/win_trusted_input_matrix.py",
          "tests/e2e/win_trusted_input_matrix_w10.py", *INPUTS)
STRIPPED = ("ZB_WIN10_HOST", "ZB_WIN10_PORT", "ZB_WIN10_USER", "ZB_WIN10_KEY", "ZB_WIN10_KNOWN_HOSTS",
            "ZB_WIN10_MARKER", "ZB_WIN10_PYTHON", "ZB_WIN10_LISTEN", "ZB_WIN_KEY", "ZB_WIN_KNOWN_HOSTS", "ZB_HOST_LIVE")

# One fake for both hosts: the target's host picks the answers. A Win10 copy lands in $ZB_FAKE_W10FS/<remote path>.
_FAKE_SSH = r"""#!/usr/bin/env bash
host=""; for a in "$@"; do case "$a" in -*) ;; *@*) host="${a#*@}" ;; esac; done
side=11; [ "$host" = "@W10@" ] && side=10
printf 'SSH%s %s\n' "$side" "$*" >> "$ZB_FAKE_LOG"
cmd="${@: -1}"
case "$cmd" in
  *.gate-identity*) if [ $side = 10 ]; then printf '%s\r\n' "$ZB_FAKE_MARKER10"; else printf '%s\r\n' "$ZB_FAKE_MARKER11"; fi; exit 0 ;;
  *Get-Process*) [ "${ZB_FAKE_CENSUS_FAIL:-}" = "$side" ] && { echo denied >&2; exit 1; }; printf 'END\r\n'; exit 0 ;;
  *Get-Item*) printf 'DIR\r\n'; exit 0 ;;
  *PRESENT*) if [ "$side" = 10 ] && [ -n "${ZB_FAKE_W10_PRESENT:-}" ]; then printf 'PRESENT\r\n'; else printf 'ABSENT\r\n'; fi; exit 0 ;;
  mkdir*) exit 0 ;;
  rmdir*) exit 0 ;;
  if\ exist*) if [ "${ZB_FAKE_LEFT:-}" = "$side" ]; then printf 'LEFT\r\n'; else printf 'GONE\r\n'; fi; exit 0 ;;
  *ws2b1-input-spike.exe*) cat "$ZB_FAKE_SPIKE_OUT"; exit "${ZB_FAKE_SPIKE_RC:-0}" ;;
esac
exit 0
"""
_FAKE_SCP = r"""#!/usr/bin/env bash
printf 'SCP %s\n' "$*" >> "$ZB_FAKE_LOG"
[ -n "${ZB_FAKE_SCP_FAIL:-}" ] && case "$*" in *"$ZB_FAKE_SCP_FAIL"*) exit 1 ;; esac
src="${@: -2:1}"; dst="${@: -1}"
case "$src" in
  *@*:*) printf 'MZfake-spike' > "$dst" ;;                            # fetch from Win11
  *) rel="${dst#*:}"; mkdir -p "$ZB_FAKE_W10FS/$(dirname "$rel")"; cp "$src" "$ZB_FAKE_W10FS/$rel" ;;
esac
exit 0
"""
_FAKE_GIT = r"""#!/usr/bin/env bash
case "$1" in
  rev-parse) echo "$ZB_FAKE_SHA"; exit 0 ;;
  show) spec="$2"; [ "${spec%%:*}" = "$ZB_FAKE_SHA" ] || exit 128; cat "$ZB_FAKE_REPO/${spec#*:}"; exit $? ;;
esac
exit 0
"""
_FAKE_BUILD = r"""#!/usr/bin/env bash
printf 'BUILD argv=[%s] commit=%s\n' "$*" "$ZB_BUILD_COMMIT" >> "$ZB_FAKE_LOG"
env | grep -E '^ZB_(WIN10_|WIN_KEY|WIN_KNOWN_HOSTS|HOST_LIVE)' | sed 's/^/BUILD-ENV /' >> "$ZB_FAKE_LOG"
[ "${ZB_FAKE_BUILD:-ok}" = fail ] && { echo "zig build failed" >&2; exit 12; }
exit 0
"""


def required_rows():
    text = (REPO / "tests" / "e2e" / "win_trusted_input_matrix.py").read_text(encoding="utf-8")
    return re.findall(r'^    "([^"\n]+)",$', text, re.M)


class Win10SpikeRun(unittest.TestCase):
    def _run(self, spike_lines=None, **over):
        t = tempfile.mkdtemp(prefix="zb-w10run-")
        self.addCleanup(shutil.rmtree, t, True)
        td = pathlib.Path(t)
        root = td / "repo"
        for rel in COPIED:
            src = REPO / rel
            if src.exists():
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, root / rel)
        build = root / "tests" / "windows" / "build-on-windows.sh"
        build.parent.mkdir(parents=True, exist_ok=True)
        build.write_text(_FAKE_BUILD)
        build.chmod(0o755)
        bindir = td / "bin"
        bindir.mkdir()
        for name, body in (("ssh", _FAKE_SSH.replace("@W10@", FAKE_WIN10_HOST)), ("scp", _FAKE_SCP), ("git", _FAKE_GIT)):
            (bindir / name).write_text(body)
            (bindir / name).chmod(0o755)
        self.log = td / "calls.log"
        self.log.write_text("")
        self.w10fs = td / "w10fs"
        self.w10fs.mkdir()
        self.tmp = td / "tmp"
        self.tmp.mkdir()
        spike = td / "spike.out"
        rows = required_rows() if spike_lines is None else spike_lines
        spike.write_text("".join(f"ok   {r}\n" for r in rows) + "SUMMARY ok\n")
        (td / "home").mkdir()
        env = {
            "PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td / "home"), "TMPDIR": str(self.tmp),
            "ZB_WIN_GATE": "1", "ZB_BUILD_COMMIT": SHA, "ZB_BUILD_MODE": "ReleaseSafe",
            "ZB_WIN11_HOST": FAKE_WIN11_HOST, "ZB_WIN11_PORT": "2222", "ZB_WIN11_USER": "zbtext",
            "ZB_WIN11_KEY": str(td / "no-such-key11"), "ZB_WIN11_KNOWN_HOSTS": str(td / "no-such-kh11"),
            "ZB_WIN11_MARKER": M11,
            "ZB_WIN10_HOST": FAKE_WIN10_HOST, "ZB_WIN10_PORT": "22", "ZB_WIN10_USER": "zbtest",
            "ZB_WIN10_KEY": str(td / "no-such-key10"), "ZB_WIN10_KNOWN_HOSTS": str(td / "no-such-kh10"),
            "ZB_WIN10_MARKER": M10,
            # inherited selectors the driver must keep from the build driver
            "ZB_WIN10_PYTHON": r"C:\py\python.exe", "ZB_WIN10_LISTEN": FAKE_WIN10_HOST,
            "ZB_WIN_KEY": str(td / "no-such-legacy"), "ZB_WIN_KNOWN_HOSTS": str(td / "no-such-legacy-kh"),
            "ZB_HOST_LIVE": "1",
            "ZB_FAKE_LOG": str(self.log), "ZB_FAKE_SHA": SHA, "ZB_FAKE_REPO": str(root), "ZB_FAKE_W10FS": str(self.w10fs),
            "ZB_FAKE_MARKER11": M11, "ZB_FAKE_MARKER10": M10, "ZB_FAKE_SPIKE_OUT": str(spike),
        }
        env.update(over)
        env = {k: v for k, v in env.items() if v is not None}
        self.assertIsNone(transport_problem(env, []), "fake Win10 run is not fail-safe")
        entry = root / "tests" / "e2e" / "win_trusted_input_matrix_w10.py"
        proc = subprocess.run([*NETNS, "python3", "-I", str(entry)], cwd=root, env=env, capture_output=True, text=True,
                              timeout=300, stdin=subprocess.DEVNULL)
        self.lines = self.log.read_text().splitlines()
        calls = [l.split(" ", 1)[1].split() for l in self.lines if l.startswith(("SSH", "SCP"))]
        self.assertIsNone(transport_problem(env, calls), "fake Win10 run is not fail-safe")
        self.out = proc.stdout + proc.stderr
        return proc

    def _idx(self, pred, start=0):
        return next((i for i, l in enumerate(self.lines) if i >= start and pred(l)), -1)

    def _ssh(self, side, needle):
        return [l for l in self.lines if l.startswith(f"SSH{side} ") and needle in l]

    def _scp(self):
        return [l[4:].split() for l in self.lines if l.startswith("SCP ")]

    def test_a_full_run_builds_on_win11_runs_on_win10_and_cleans_both(self):
        proc = self._run()
        self.assertEqual(proc.returncode, 0, self.out[-3000:])
        self.assertIn(f"HOST\twin11\tidentity_marker={M11}", proc.stdout)
        self.assertIn(f"HOST\twin10\tidentity_marker={M10}", proc.stdout)
        digest = hashlib.sha256(b"MZfake-spike").hexdigest()
        self.assertRegex(proc.stdout, rf"EXE\t\S*{re.escape(EXE)}\tsha256={digest}\tcommit={SHA}")
        self.assertIn(f"ASSERTS {len(required_rows())}", proc.stdout)
        self.assertIn("PASS\tws2b1-trusted-input-matrix-w10", proc.stdout)
        builds = [l for l in self.lines if l.startswith("BUILD argv")]
        self.assertEqual(builds, [f"BUILD argv=[{STEP}] commit={SHA}"])
        self.assertEqual([l for l in self.lines if l.startswith("BUILD-ENV")], [],
                         "a Win10 or legacy selector reached the build driver")

    def test_both_markers_and_censuses_and_the_absence_check_come_before_the_build(self):
        self._run()
        build = self._idx(lambda l: l.startswith("BUILD argv"))
        for side in (11, 10):
            self.assertTrue(0 <= self._idx(lambda l, s=side: l.startswith(f"SSH{s} ") and ".gate-identity" in l) < build)
            self.assertTrue(0 <= self._idx(lambda l, s=side: l.startswith(f"SSH{s} ") and "Get-Process" in l) < build)
        self.assertTrue(0 <= self._idx(lambda l: l.startswith("SSH10 ") and "PRESENT" in l) < build)

    def test_the_exe_is_fetched_from_the_exact_win11_build_folder_over_legacy_scp(self):
        self._run()
        fetch = [a for a in self._scp() if any(x.endswith(f":{REL_DIR}/zig-out/bin/{EXE}") for x in a)]
        self.assertEqual(len(fetch), 1, self._scp())
        self.assertIn(f"zbtext@{FAKE_WIN11_HOST}:{REL_DIR}/zig-out/bin/{EXE}", fetch[0])
        self.assertLess(fetch[0].index("-O"), next(i for i, x in enumerate(fetch[0]) if "@" in x))

    def test_the_win11_build_folder_is_removed_after_the_fetch_and_before_win10_staging(self):
        self._run()
        fetch = self._idx(lambda l: l.startswith("SCP ") and f"/zig-out/bin/{EXE}" in l)
        rm11 = self._idx(lambda l: l.startswith("SSH11 ") and l.endswith(f'rmdir /s /q "{WIN_DIR}"'))
        mk10 = self._idx(lambda l: l.startswith("SSH10 ") and "mkdir" in l)
        self.assertTrue(0 <= fetch < rm11 < mk10, (fetch, rm11, mk10))
        self.assertEqual(len(self._ssh(11, "rmdir")), 1)

    def test_win10_gets_exactly_the_exe_and_the_inputs_of_the_commit_in_its_run_folder(self):
        self._run()
        staged = sorted(p.relative_to(self.w10fs).as_posix() for p in self.w10fs.rglob("*") if p.is_file())
        want = sorted([f"{REL_DIR}/{EXE}"] + [f"{REL_DIR}/{pathlib.PurePosixPath(r).name}" for r in INPUTS])
        self.assertEqual(staged, want)
        for rel in INPUTS:
            self.assertEqual((self.w10fs / REL_DIR / pathlib.PurePosixPath(rel).name).read_bytes(),
                             (REPO / rel).read_bytes(), f"{rel} is not the commit's file")
        for argv in self._scp():
            dests = [x for x in argv if x.startswith(f"zbtest@{FAKE_WIN10_HOST}:")]
            for d in dests:
                self.assertTrue(d.startswith(f"zbtest@{FAKE_WIN10_HOST}:{REL_DIR}/"), d)
            if dests or any("@" in x for x in argv):
                self.assertLess(argv.index("-O"), next(i for i, x in enumerate(argv) if "@" in x), argv)
        mk = self._ssh(10, "mkdir")
        self.assertEqual(len(mk), 1)
        self.assertTrue(mk[0].endswith(f'mkdir "{WIN_DIR}"'), mk[0])

    def test_the_spike_runs_in_the_win10_folder_and_the_folder_is_removed_through_the_helper(self):
        self._run()
        run = self._idx(lambda l: l.startswith("SSH10 ") and EXE in l and "cd /d" in l)
        self.assertGreaterEqual(run, 0)
        self.assertTrue(self.lines[run].endswith(f'cd /d "{WIN_DIR}" && {EXE} input.html scroll.html automation.js'),
                        self.lines[run])
        census = self._idx(lambda l: l.startswith("SSH10 ") and "Get-Process" in l, run)
        rm10 = self._idx(lambda l: l.startswith("SSH10 ") and l.endswith(f'rmdir /s /q "{WIN_DIR}"'), run)
        self.assertTrue(run < census < rm10, (run, census, rm10))
        self.assertEqual(len(self._ssh(10, "rmdir")), 1)
        self.assertEqual(list(self.tmp.iterdir()), [], "the driver left local files behind")

    def test_a_missing_win10_key_is_refused_before_any_transport(self):
        proc = self._run(ZB_WIN10_KEY=None)
        self.assertEqual(proc.returncode, 1, self.out)
        self.assertIn("ZB_WIN10_KEY", self.out)
        self.assertEqual([l for l in self.lines if l.startswith(("SSH", "SCP", "BUILD"))], [])

    def test_a_wrong_win10_marker_stops_before_the_build(self):
        proc = self._run(ZB_FAKE_MARKER10="someone-else")
        self.assertEqual(proc.returncode, 1, self.out)
        self.assertEqual([l for l in self.lines if l.startswith("BUILD")], [])
        self.assertEqual(self._ssh(10, "mkdir") + self._ssh(10, "rmdir") + self._ssh(11, "rmdir"), [])

    def test_an_existing_win10_run_folder_is_refused_and_left_alone(self):
        proc = self._run(ZB_FAKE_W10_PRESENT="1")
        self.assertEqual(proc.returncode, 1, self.out)
        self.assertEqual([l for l in self.lines if l.startswith("BUILD")], [])
        self.assertEqual(self._ssh(10, "mkdir") + self._ssh(10, "rmdir"), [])

    def test_a_failed_build_cleans_win11_and_never_touches_win10(self):
        proc = self._run(ZB_FAKE_BUILD="fail")
        self.assertEqual(proc.returncode, 1, self.out)
        self.assertEqual(len(self._ssh(11, "rmdir")), 1)
        self.assertEqual(self._ssh(10, "mkdir") + self._ssh(10, "rmdir") + self._ssh(10, EXE), [])

    def test_a_failed_staging_copy_still_cleans_the_win10_folder(self):
        proc = self._run(ZB_FAKE_SCP_FAIL=f"{REL_DIR}/scroll.html")
        self.assertEqual(proc.returncode, 1, self.out)
        self.assertEqual(self._ssh(10, EXE + " input.html"), [], "the spike ran with a partial staging")
        self.assertEqual(len(self._ssh(10, "rmdir")), 1)

    def test_a_failing_row_fails_the_run_and_still_cleans(self):
        rows = required_rows()
        proc = self._run(spike_lines=rows[:-1] + ["FAIL " + rows[-1]])
        self.assertEqual(proc.returncode, 1, self.out)
        self.assertNotIn("PASS\tws2b1-trusted-input-matrix-w10", proc.stdout)
        self.assertEqual(len(self._ssh(10, "rmdir")), 1)

    def test_a_missing_required_row_fails_the_run(self):
        proc = self._run(spike_lines=required_rows()[:-1])
        self.assertEqual(proc.returncode, 1, self.out)
        self.assertNotIn("PASS\tws2b1-trusted-input-matrix-w10", proc.stdout)

    def test_a_win10_cleanup_that_leaves_the_folder_fails_the_run(self):
        proc = self._run(ZB_FAKE_LEFT="10")
        self.assertEqual(proc.returncode, 1, self.out)
        self.assertEqual(len(self._ssh(10, "rmdir")), 1, "no retry")


if __name__ == "__main__":
    unittest.main()
