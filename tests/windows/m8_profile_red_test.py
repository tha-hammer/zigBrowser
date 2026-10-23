#!/usr/bin/env python3
r"""WS0.4/WS1.2 RED (UNREGISTERED), NavyCanyon e80e0352: every real m8 browser launch gets its own explicit WebView2
user-data folder under the run's own directory, and no inherited override can redirect it.

The 73f184be Win11 run failed m8_reply_channel_test with CreateCoreWebView2Controller 0x800700AA (ERROR_BUSY): all
five browser launches (render 1, reply 2, load-fail 2) started the same staged exe without --profile-dir, so WebView2
used the one shared `<exe>.WebView2` folder beside it (src/webview2_shim.cpp: --profile-dir <d> -> <d>\WebView2;
empty -> WebView2's default). slice2_common also forwards WEBVIEW2_* variables, so an inherited
WEBVIEW2_USER_DATA_FOLDER (or the WebView2 UserDataFolder policy in the registry) could redirect every launch to one
shared folder.

Pinned:
  - command capture: the REAL m8_render_test / m8_reply_channel_test / m8_load_fail_test main() run with recording
    runners (the slice2_common runner names they import are replaced; nothing is launched). Exactly five launches;
    each carries an explicit profile dir (`--profile-dir <d>`, or `-ProfileDir <d>` to the render capture script,
    which passes `--profile-dir` on); all five are distinct (both reply launches too); each is an existing directory
    under the run's own directory (the test's cwd, which m8_live_test sets to runs\<id>); each test prints
    `WEBVIEW2_USER_DATA\t<label>\t<d>\WebView2`, the effective folder; no launch env carries a WEBVIEW2_USER_DATA_FOLDER;
  - the runners (ps1 and cmd) refuse an env that carries WEBVIEW2_USER_DATA_FOLDER: a failing result naming it, and
    no scheduled task is created;
  - the render capture script passes its -ProfileDir on as `--profile-dir` (a tripwire on the script text: no
    PowerShell here; the Win11 run proves it);
  - browser_profile_dir refuses a label that would leave the run root, and creates nothing outside it;
  - the generated task wrapper refuses, on the host, a WEBVIEW2_USER_DATA_FOLDER in the task's own environment and a
    WebView2 UserDataFolder policy (HKCU/HKLM Software\Policies\Microsoft\Edge\WebView2\UserDataFolder) before it
    launches anything. This is a tripwire on the generated text; the Win11 run proves it.
Hostless; no host value appears anywhere.

Run alone:  python3 -I tests/windows/m8_profile_red_test.py -v
"""
import json
import pathlib
import shlex
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
E2E = REPO / "tests" / "e2e"

_CAPTURE_CHILD = r"""
import importlib, json, os, sys
sys.path.insert(0, sys.argv[1])
which = sys.argv[2]
import slice2_common as s
mod = importlib.import_module(which)

class _Windows:
    @staticmethod
    def system():
        return "Windows"

mod.platform = _Windows
launches = []

def _recorder(kind):
    def record(cmd, env, timeout_sec, *args, **kwargs):
        launches.append({"kind": kind, "cmd": [str(c) for c in cmd],
                         "webview2_env": sorted(k for k in env if k.upper().startswith("WEBVIEW2_"))})
        result = s.RunResult(0, ['{"NonUniform": true}', "ZB_HARNESS_EXIT\t0"], [], set())
        return result if kind == "to_exit" else (True, result)
    return record

for name, kind in (("run_windows_interactive_until", "until"), ("run_windows_interactive_cmd_until", "cmd_until"),
                   ("run_windows_interactive_to_exit", "to_exit")):
    if hasattr(mod, name):
        setattr(mod, name, _recorder(kind))
if hasattr(mod, "powershell_exe"):
    mod.powershell_exe = lambda: "powershell.exe"
extra = ["--fail-uri", "http://127.0.0.1:9/", "--mode", "all"] if which == "m8_load_fail_test" else ["--index", "index.html"]
sys.argv = [which, "--binary", "zigBrowser.exe", *extra]
try:
    rc = mod.main()
except SystemExit as e:
    rc = e.code
except Exception as e:
    rc = "raised " + repr(e)
render_args = [l.strip() for l in getattr(mod, "RENDER_CAPTURE_PS1", "").splitlines()
               if l.strip().startswith("$browserArgs")]
print("LAUNCHES " + json.dumps({"rc": rc, "launches": launches, "render_args": render_args}))
"""

_FAKE_SCHTASKS = r"""#!/usr/bin/env bash
printf 'schtasks' >> "$ZB_FAKE_LOG"; printf ' %q' "$@" >> "$ZB_FAKE_LOG"; printf '\n' >> "$ZB_FAKE_LOG"
verb="$1"; shift; tn=""; tr=""
while [ $# -gt 0 ]; do case "$1" in /tn) tn="$2"; shift 2 ;; /tr) tr="$2"; shift 2 ;; *) shift ;; esac; done
case "$verb" in
  /create) printf '%s' "$tr" > "$ZB_FAKE_STATE/$tn.tr" ;;
  /run) script=$(sed -E 's/.*"([^"]+)"[^"]*$/\1/' "$ZB_FAKE_STATE/$tn.tr"); dir=$(dirname "$script")
        printf 'PASS\tfake\nZB_HARNESS_EXIT\t0\n' > "$dir/stdout.txt"; : > "$dir/stderr.txt"; echo 4242 > "$dir/pid.txt"
        printf 'ZB_RUNNER_JOB\tdrained\t0\n' > "$dir/job.txt"; echo 0 > "$dir/exit.txt" ;;
esac
exit 0
"""

_RUNNER_CHILD = r"""
import json, os, sys, pathlib
sys.path.insert(0, sys.argv[1])
import slice2_common as s

class _WindowsName:
    name = "nt"
    def __getattr__(self, attr):
        return getattr(os, attr)

s.os = _WindowsName()
which, override = sys.argv[2], sys.argv[3]
env = {"ZB_X": "1"}
if override:
    env["WEBVIEW2_USER_DATA_FOLDER"] = override
cond = lambda o, e, p: p.returncode is not None
if which == "ps1":
    matched, r = s.run_windows_interactive_until(["C:\\zb\\fake.exe"], env, 10, cond, cwd=pathlib.Path.cwd())
else:
    matched, r = s.run_windows_interactive_cmd_until(["C:\\zb\\fake.exe"], env, 10, cond, cwd=pathlib.Path.cwd())
print(json.dumps({"returncode": r.returncode, "stderr": r.stderr_lines}))
"""

_HELPER_CHILD = r"""
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
import slice2_common as s
out = {}
for label in ("../../escape", "../../../escape", "a/../../../escape", ""):
    try:
        s.browser_profile_dir(pathlib.Path(sys.argv[2]), label)
        out[label] = "accepted"
    except ValueError:
        out[label] = "refused"
print(json.dumps(out))
"""

TESTS = {"m8_render_test": 1, "m8_reply_channel_test": 2, "m8_load_fail_test": 2}


def _profile_of(launch):
    cmd = launch["cmd"]
    for flag in ("--profile-dir", "-ProfileDir"):
        if flag in cmd and cmd.index(flag) + 1 < len(cmd):
            return cmd[cmd.index(flag) + 1]
    return None


class M8ProfilesRed(unittest.TestCase):
    def _capture(self, which, run_root):
        (run_root / "zigBrowser.exe").write_text("fake exe")
        (run_root / "index.html").write_text("<html><head><title>Fixture</title></head><body>x</body></html>")
        proc = subprocess.run(["python3", "-I", "-c", _CAPTURE_CHILD, str(E2E), which], cwd=run_root,
                              env={"PATH": "/usr/bin:/bin", "HOME": str(run_root), "TMPDIR": str(run_root),
                                   "ZB_ENABLE_M8_E2E": "1", "ZB_WIN_GATE": "1"},
                              capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
        detail = f"\n{which}: rc={proc.returncode}\nstdout:\n{proc.stdout[-3000:]}\nstderr:\n{proc.stderr[-3000:]}"
        rows = [l for l in proc.stdout.splitlines() if l.startswith("LAUNCHES ")]
        self.assertEqual(len(rows), 1, "the capture child must report its launches" + detail)
        report = json.loads(rows[0][len("LAUNCHES "):])
        if which == "m8_render_test":
            args = report["render_args"]
            self.assertEqual(len(args), 1, "one $browserArgs line in the render capture script" + detail)
            self.assertIn('"--profile-dir", (\'"\' + $ProfileDir + \'"\')', args[0],
                          "the capture script passes -ProfileDir on to the browser" + detail)
        return report["launches"], proc.stdout, detail

    def test_every_m8_browser_launch_gets_its_own_profile_under_the_run_root(self):
        with tempfile.TemporaryDirectory() as t:
            run_root = pathlib.Path(t).resolve()
            seen, details = [], ""
            for which, expected in TESTS.items():
                launches, stdout, detail = self._capture(which, run_root)
                details += detail
                self.assertEqual(len(launches), expected, f"{which} launches the browser {expected}x" + detail)
                for launch in launches:
                    profile = _profile_of(launch)
                    self.assertIsNotNone(profile, f"{which}: an explicit profile dir per launch: {launch['cmd']}" + detail)
                    path = pathlib.Path(profile).resolve()
                    self.assertIn(run_root, path.parents, f"{which}: {profile} is under the run root" + detail)
                    self.assertTrue(path.is_dir(), f"{which}: {profile} exists" + detail)
                    self.assertIn(f"\t{profile}\\WebView2", stdout, f"{which}: the effective folder is printed" + detail)
                    self.assertNotIn("WEBVIEW2_USER_DATA_FOLDER", launch["webview2_env"], detail)
                    seen.append(profile)
            self.assertEqual(len(seen), 5, "render 1 + reply 2 + load-fail 2" + details)
            self.assertEqual(len(set(seen)), 5, f"all five profile dirs are distinct: {seen}" + details)

    def test_the_profile_helper_refuses_a_label_that_leaves_the_run_root(self):
        with tempfile.TemporaryDirectory() as t:
            outer = pathlib.Path(t).resolve()
            run_root = outer / "runs" / "r1"
            run_root.mkdir(parents=True)
            proc = subprocess.run(["python3", "-I", "-c", _HELPER_CHILD, str(E2E), str(run_root)], cwd=outer,
                                  env={"PATH": "/usr/bin:/bin", "HOME": str(outer), "TMPDIR": str(outer)},
                                  capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertEqual(proc.returncode, 0, detail)
            verdicts = json.loads(proc.stdout.strip().splitlines()[-1])
            self.assertEqual(set(verdicts.values()), {"refused"}, f"{verdicts}" + detail)
            outside = sorted(str(q.relative_to(outer)) for q in outer.rglob("*")
                             if q != run_root and run_root not in q.parents and q not in run_root.parents)
            self.assertEqual(outside, [], "nothing is created outside the run root" + detail)

    def _runner(self, which, override):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir()
            state = td / "state"; state.mkdir()
            (bindir / "schtasks").write_text(_FAKE_SCHTASKS); (bindir / "schtasks").chmod(0o755)
            log = td / "calls.log"; log.write_text("")
            proc = subprocess.run(["python3", "-I", "-c", _RUNNER_CHILD, str(E2E), which, override], cwd=td,
                                  env={"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td),
                                       "ZB_FAKE_LOG": str(log), "ZB_FAKE_STATE": str(state)},
                                  capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
            calls = [shlex.split(c) for c in log.read_text().splitlines()]
            wrappers = [w.read_text() for w in td.glob("zb_m8_*/*.ps1")]
        detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls: {calls}"
        self.assertEqual(proc.returncode, 0, "the child driver itself must not crash" + detail)
        return json.loads(proc.stdout.strip().splitlines()[-1]), calls, wrappers, detail

    def test_the_runners_refuse_an_inherited_webview2_user_data_folder(self):
        for which in ("ps1", "cmd"):
            with self.subTest(runner=which):
                result, calls, _, detail = self._runner(which, r"C:\shared\wv2")
                self.assertNotEqual(result["returncode"], 0, detail)
                self.assertTrue(any("WEBVIEW2_USER_DATA_FOLDER" in l for l in result["stderr"]), detail)
                self.assertFalse([c for c in calls if c[:2] == ["schtasks", "/create"]], "no task is created" + detail)

    def test_the_task_wrapper_refuses_a_host_side_override_before_launching(self):
        # tripwire on the generated PowerShell (no pwsh here; the Win11 run proves it)
        for which in ("ps1", "cmd"):
            with self.subTest(runner=which):
                result, _, wrappers, detail = self._runner(which, "")
                self.assertEqual(result["returncode"], 0, detail)
                self.assertEqual(len(wrappers), 1, detail)
                w = wrappers[0]
                self.assertIn("$env:WEBVIEW2_USER_DATA_FOLDER", w, detail)
                self.assertIn(r"Software\Policies\Microsoft\Edge\WebView2\UserDataFolder", w, detail)
                self.assertLess(w.index(r"Software\Policies\Microsoft\Edge\WebView2\UserDataFolder"),
                                w.index("[ZbJob]::Launch("), "checked before the launch" + detail)


if __name__ == "__main__":
    unittest.main()
