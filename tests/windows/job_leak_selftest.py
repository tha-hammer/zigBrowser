#!/usr/bin/env python3
r"""zigBrowser-ong.21 RED (UNREGISTERED): the live lingering-child proof, both layers (NavyCanyon c67cd222).

Plan rev 2.21 WS0.4 follow-up (NavyCanyon af9b3cba): on Win11, a program whose child outlives it past the production
drain budget (slice2_common.JOB_DRAIN_DEADLINE_SEC, 60 s) is reported as `survivors n`, contained by closing the job,
and its row FAILS, through BOTH slice2_common runners (PowerShell and cmd); a short-lived child drains (`drained 0`).

Three seams, each driven here without any host:

  A. tests/e2e/slice2_common.py: ONE strict parser, parse_job_census(raw) -> (verdict, count) | None, and a structured
     RunResult.job_census filled from it by both real runners. Absent, malformed, duplicate or contradictory census
     data is None (fail closed); _census_problem keeps its diagnostics. Driven: the parser directly, and both REAL
     runners in a child Python with the recording fake schtasks of runner_ws04_job_red_test.py.

  B. tests/e2e/win_job_leak_rows.py, the Windows-side module (staged and run ON Win11 by C). run_rows(helper,
     runners, out) runs four rows in order: ps1-linger, ps1-short, cmd-linger, cmd-short. Each row runs the helper
     `[helper, "parent", "<child ms>"]` through the real runner; the parent starts its child, proves it alive
     (`WS04\tCHILD\t<pid>\talive`) and exits 0. A lingering row is EXPECTED only with the parent's own exit 0
     (its ZB_HARNESS_EXIT row), job_census == ("survivors", n > 0), a nonzero runner result and the existing
     "closing the job contained them" diagnostic; a short row only with exit 0, ("drained", 0) and result 0.
     Output: `ROW\t<runner>-<kind>\tEXPECTED\t<verdict>\t<n>` or `ROW\t<runner>-<kind>\tUNEXPECTED\t<why>`; the first
     unexpected row stops the run (no later row runs); all four expected -> `PASS\twin-job-leak`, `ASSERTS <n>` (n > 0),
     0. The lingering child outlives the production 60 s budget by a clear bounded margin, the short child exits well
     inside it, and the module never shortens the budget. It makes no process call of its own (no kill of any kind).
     Driven: run_rows with controlled runner results.

  C. tests/windows/job_leak_live_test.py, the Linux-side live driver (a ZB_WIN_GATE=1 live step; main(argv) with
     `--helper <ws04-linger.exe>`). It resolves the complete ZB_WIN11_{HOST,PORT,USER,KEY,KNOWN_HOSTS,MARKER} contract
     through live_transport before ANY transport call (partial -> `refused:` rc 2; no host -> 1 under the gate, 77
     standalone; legacy ZB_WIN_KEY / ZB_WIN_KNOWN_HOSTS and every ZB_WIN10_* ignored), checks the identity marker,
     takes webview2_cleanup.census BEFORE creating, staging or launching anything, creates %USERPROFILE%\zb\runs\
     m8-<pid>-<12 hex> (the accepted m8 shape), stages ws04-linger.exe, tests\e2e\slice2_common.py and
     tests\e2e\win_job_leak_rows.py there, runs the module with TEMP/TMP inside the folder, requires its four
     expected rows + PASS + ASSERTS n > 0, requires no zb_m8_* scheduled task left, and in `finally` calls
     webview2_cleanup.remove_after_webview2 EXACTLY ONCE with that same before-census object, once this run created
     the folder (a failed create deletes nothing, as 8974649e). No raw rmdir, no kill, no retry, no second cleanup.
     Output: `RESULT\twin11\twin-job-leak\tPASS\tASSERTS <n>` and one `ASSERTS <n>` (n > 0), rc 0; any defect rc 1.
     The driver calls the shared helper through its module (webview2_cleanup.census / .remove_after_webview2).
     Driven in-process with recording fake ssh/scp first on PATH (TEST-NET 192.0.2.1, keys that do not exist), a
     fake clock for the shared helper, fake_transport.problem() on every logged call; run in
     `unshare --user --map-current-user --net`.

Red: every test fails because parse_job_census / RunResult.job_census / win_job_leak_rows.py / job_leak_live_test.py
do not exist yet. Run alone:  unshare --user --map-current-user --net python3 -I tests/windows/job_leak_selftest.py -v
"""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]
E2E = REPO / "tests" / "e2e"
sys.path.insert(0, str(HERE))  # `python3 -I` drops the script dir
sys.path.insert(1, str(E2E))
import fake_transport  # noqa: E402
import runner_ws04_job_red_test as ws04  # noqa: E402  the recording fake schtasks of the WS0.4 runner test
import slice2_common  # noqa: E402
import webview2_cleanup  # noqa: E402

MODULE = E2E / "win_job_leak_rows.py"
DRIVER = HERE / "job_leak_live_test.py"
CONTAINED = "closing the job contained them"
ROW_ORDER = ("ps1-linger", "ps1-short", "cmd-linger", "cmd-short")
KILLS = re.compile(r"taskkill|Stop-Process|\bkill\b|TerminateProcess|wmic\b", re.I)


def load(path: pathlib.Path, name: str):
    """The module at `path`, freshly loaded (a missing file fails the calling test, not the whole file)."""
    if not path.is_file():
        raise AssertionError(f"{path.relative_to(REPO)} does not exist yet")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------------------------------------------------- A ----
class StrictJobCensusParser(unittest.TestCase):
    VALID = {
        "ZB_RUNNER_JOB\tdrained\t0\n": ("drained", 0),
        "\ufeffZB_RUNNER_JOB\tsurvivors\t3\r\n": ("survivors", 3),
        "ZB_RUNNER_JOB\tleft\t2\n": ("left", 2),
        "ZB_RUNNER_JOB\tstopped\t1\n": ("stopped", 1),
    }
    INVALID = (
        None, "", "\n", "junk\n",
        "ZB_RUNNER_JOB\tdrained\t3\n",          # contradictory: drained with processes
        "ZB_RUNNER_JOB\tsurvivors\t0\n",        # contradictory: survivors without any
        "ZB_RUNNER_JOB\tleft\t0\n", "ZB_RUNNER_JOB\tstopped\t0\n",
        "ZB_RUNNER_JOB\tkilled\t2\n",           # 25fa071's retired verdict
        "ZB_RUNNER_JOB\tdrained\n", "ZB_RUNNER_JOB\tdrained\tx\n", "ZB_RUNNER_JOB\tdrained\t-1\n",
        "ZB_RUNNER_JOB\tsurvivors\t+2\n", "ZB_RUNNER_JOB\tdrained\t0\textra\n", "ZB_RUNNER\tdrained\t0\n",
        "ZB_RUNNER_JOB\tdrained\t0\nZB_RUNNER_JOB\tdrained\t0\n",      # duplicate
        "ZB_RUNNER_JOB\tsurvivors\t1\nZB_RUNNER_JOB\tdrained\t0\n",    # duplicate and contradictory
    )

    def test_every_valid_census_line_is_one_structured_pair(self):
        parse = getattr(slice2_common, "parse_job_census", None)
        self.assertTrue(callable(parse), "slice2_common.parse_job_census is the one strict parser")
        for raw, want in self.VALID.items():
            with self.subTest(raw=raw):
                self.assertEqual(parse(raw), want)

    def test_absent_malformed_duplicate_or_contradictory_census_is_none(self):
        parse = getattr(slice2_common, "parse_job_census", None)
        self.assertTrue(callable(parse), "slice2_common.parse_job_census is the one strict parser")
        for raw in self.INVALID:
            with self.subTest(raw=raw):
                self.assertIsNone(parse(raw))

    def test_run_result_carries_an_optional_structured_census(self):
        r = slice2_common.RunResult(returncode=0, stdout_lines=[], stderr_lines=[], tracked_children=set())
        self.assertTrue(hasattr(r, "job_census"), "RunResult.job_census (verdict, count) | None")
        self.assertIsNone(r.job_census, "it defaults to None: no census is never a pass")


_CHILD = r"""
import json, os, sys, pathlib
sys.path.insert(0, sys.argv[1])
import slice2_common as s

class _WindowsName:
    name = "nt"
    def __getattr__(self, attr):
        return getattr(os, attr)

s.os = _WindowsName()
which, until, timeout = sys.argv[2], sys.argv[3], float(sys.argv[4])
s.JOB_DRAIN_DEADLINE_SEC = 3.0   # the hostless run only; the live module never shortens it
s.JOB_CENSUS_GRACE_SEC = 1.0
cond = {"exit": lambda o, e, p: p.returncode is not None,
        "ready": lambda o, e, p: any(l.startswith("READY") for l in o)}[until]
runner = s.run_windows_interactive_until if which == "ps1" else s.run_windows_interactive_cmd_until
matched, r = runner(["C:\\zb\\fake.exe"], {}, timeout, cond, cwd=pathlib.Path.cwd())
census = getattr(r, "job_census", "MISSING")
print(json.dumps({"matched": matched, "returncode": r.returncode, "stderr": r.stderr_lines,
                  "job_census": list(census) if isinstance(census, tuple) else census}))
"""


class BothRunnersExposeTheStructuredCensus(unittest.TestCase):
    def _run(self, which, job, until="exit"):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir()
            state = td / "state"; state.mkdir()
            for name, body in (("schtasks", ws04._FAKE_SCHTASKS), ("taskkill", ws04._FAKE_TASKKILL)):
                (bindir / name).write_text(body); (bindir / name).chmod(0o755)
            log = td / "calls.log"; log.write_text("")
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td),
                   "ZB_FAKE_LOG": str(log), "ZB_FAKE_STATE": str(state), "ZB_FAKE_JOB": job}
            proc = subprocess.run([sys.executable, "-I", "-c", _CHILD, str(E2E), which, until, "20"], cwd=td,
                                  env=env, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
            calls = [shlex.split(c) for c in log.read_text().splitlines()]
        detail = f"\nchild rc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        self.assertEqual(proc.returncode, 0, "the child driver itself must not crash" + detail)
        self.assertFalse([c for c in calls if c[:1] == ["taskkill"]], "no pid taskkill, ever" + detail)
        result = json.loads(proc.stdout.strip().splitlines()[-1])
        self.assertNotEqual(result["job_census"], "MISSING", "RunResult.job_census exists" + detail)
        return result, detail

    def test_survivors_are_structured_contained_and_fail_on_both_runners(self):
        for which in ws04.RUNNERS:
            with self.subTest(runner=which):
                r, detail = self._run(which, r"census:ZB_RUNNER_JOB\tsurvivors\t2")
                self.assertEqual(r["job_census"], ["survivors", 2], detail)
                self.assertNotEqual(r["returncode"], 0, "a survivor census fails the row" + detail)
                self.assertTrue(any(CONTAINED in l for l in r["stderr"]), "the containment diagnostic" + detail)

    def test_a_drained_job_is_structured_and_passes_on_both_runners(self):
        for which in ws04.RUNNERS:
            with self.subTest(runner=which):
                r, detail = self._run(which, r"census:ZB_RUNNER_JOB\tdrained\t0")
                self.assertEqual(r["job_census"], ["drained", 0], detail)
                self.assertEqual(r["returncode"], 0, detail)

    def test_left_and_a_requested_stop_are_structured(self):
        for which in ws04.RUNNERS:
            with self.subTest(runner=which, job="left"):
                r, detail = self._run(which, r"census:ZB_RUNNER_JOB\tleft\t2")
                self.assertEqual(r["job_census"], ["left", 2], detail)
                self.assertNotEqual(r["returncode"], 0, detail)
            with self.subTest(runner=which, job="stop"):
                r, detail = self._run(which, "stop", until="ready")
                self.assertEqual(r["job_census"], ["stopped", 1], detail)
                self.assertEqual(r["returncode"], 0, "a matched stop still passes" + detail)

    def test_absent_duplicate_or_contradictory_census_is_none_and_fails(self):
        for job in ("none", r"census:ZB_RUNNER_JOB\tdrained\t0\nZB_RUNNER_JOB\tdrained\t0",
                    r"census:ZB_RUNNER_JOB\tdrained\t3", r"census:ZB_RUNNER_JOB\tsurvivors\t0"):
            for which in ws04.RUNNERS:
                with self.subTest(runner=which, job=job):
                    r, detail = self._run(which, job)
                    self.assertIsNone(r["job_census"], "invalid census data is no structured census" + detail)
                    self.assertNotEqual(r["returncode"], 0, "and it fails closed" + detail)


# ---------------------------------------------------------------------------------------------------------- B ----
def run_result(census, returncode, exit_row=0, child=True, contained=None):
    """A runner result as the real runners build it: the program's stdout ends with its ZB_HARNESS_EXIT row."""
    out = []
    if child:
        out.append("WS04\tCHILD\t5150\talive")
    if exit_row is not None:
        out.append(f"{slice2_common.HARNESS_EXIT_PREFIX}\t{exit_row}")
    err = []
    if contained if contained is not None else (census is not None and census[0] == "survivors"):
        err.append(f"runner: {census[1] if census else 1} process(es) of the run were still alive at the 60 s drain "
                   f"deadline; {CONTAINED}, and the run fails")
    r = slice2_common.RunResult(returncode=returncode, stdout_lines=out, stderr_lines=err, tracked_children=set())
    r.job_census = census
    return r


GOOD = {"linger": lambda: run_result(("survivors", 1), 1), "short": lambda: run_result(("drained", 0), 0)}


class FakeRunners:
    """Controlled results for run_rows: `results` maps a row label to a factory; every call is recorded."""

    def __init__(self, overrides=None):
        self.overrides = overrides or {}
        self.calls = []

    def _runner(self, which):
        def run(cmd, env, timeout_sec, condition, cwd=None, **kw):
            try:  # the row is what the module asked for: a child longer than the drain budget lingers
                kind = "linger" if int(cmd[2]) > slice2_common.JOB_DRAIN_DEADLINE_SEC * 1000 else "short"
            except (IndexError, ValueError, TypeError):
                kind = "malformed"
            label = f"{which}-{kind}"
            self.calls.append((label, list(cmd), timeout_sec))
            make = self.overrides.get(label, GOOD.get(kind, lambda: run_result(None, 1)))
            r = make()
            return (r.returncode == 0), r
        return run

    def runners(self):
        return {"ps1": self._runner("ps1"), "cmd": self._runner("cmd")}


def _refuse_process(*a, **k):
    raise AssertionError(f"the module made a process call of its own: {a!r}")


class WindowsModuleRows(unittest.TestCase):
    def setUp(self):
        self.mod = load(MODULE, "win_job_leak_rows_under_test")

    def go(self, overrides=None):
        fakes = FakeRunners(overrides)
        out = io.StringIO()
        with mock.patch.object(subprocess, "Popen", _refuse_process), \
                mock.patch.object(subprocess, "run", _refuse_process), mock.patch.object(os, "system", _refuse_process):
            rc = self.mod.run_rows("ws04-linger.exe", runners=fakes.runners(), out=out)
        text = out.getvalue()
        rows = [l.split("\t") for l in text.splitlines() if l.startswith("ROW\t")]
        return rc, rows, text, fakes.calls

    def test_four_expected_rows_pass_in_order(self):
        rc, rows, text, calls = self.go()
        self.assertEqual(rc, 0, text)
        self.assertEqual([c[0] for c in calls], list(ROW_ORDER), "ps1 then cmd, lingering row first")
        self.assertEqual([r[1] for r in rows], list(ROW_ORDER), text)
        self.assertEqual([r[2] for r in rows], ["EXPECTED"] * 4, text)
        self.assertEqual([tuple(r[3:5]) for r in rows],
                         [("survivors", "1"), ("drained", "0"), ("survivors", "1"), ("drained", "0")], text)
        self.assertEqual([l for l in text.splitlines() if l.startswith("PASS\t")], ["PASS\twin-job-leak"], text)
        n = re.findall(r"^ASSERTS (\d+)$", text, re.M)
        self.assertEqual(len(n), 1, text)
        self.assertGreater(int(n[0]), 0, text)

    def test_the_helper_runs_as_parent_with_a_long_then_short_child(self):
        _, _, text, calls = self.go()
        budget = slice2_common.JOB_DRAIN_DEADLINE_SEC
        self.assertEqual(budget, 60.0, "the production drain budget is untouched by the module")
        for label, cmd, timeout in calls:
            with self.subTest(row=label):
                self.assertEqual(cmd[:2], ["ws04-linger.exe", "parent"], text)
                ms = int(cmd[2])
                if label.endswith("linger"):
                    self.assertGreaterEqual(ms / 1000, budget + 30, "outlives the 60 s drain by a clear margin")
                    self.assertLessEqual(ms / 1000, budget + 120, "and stays bounded")
                else:
                    self.assertLessEqual(ms / 1000, budget / 4, "the control exits well inside the drain")
                self.assertTrue(0 < timeout <= 300, f"a bounded runner timeout: {timeout}")

    def _unexpected_at(self, label, make, why=""):
        rc, rows, text, calls = self.go({label: make})
        at = ROW_ORDER.index(label)
        self.assertEqual(rc, 1, text)
        self.assertEqual([c[0] for c in calls], list(ROW_ORDER[: at + 1]), "no later row runs" + text)
        self.assertEqual([r[2] for r in rows], ["EXPECTED"] * at + ["UNEXPECTED"], text)
        self.assertNotIn("PASS\t", text)
        return text

    def test_a_lingering_row_is_expected_only_as_contained_survivors(self):
        for label in ("ps1-linger", "cmd-linger"):
            for why, make in {
                "drained instead of survivors": lambda: run_result(("drained", 0), 0),
                # the census itself decides: a drained census never passes a lingering row, whatever else fails
                "drained with a failing result": lambda: run_result(("drained", 0), 1, contained=True),
                "no structured census": lambda: run_result(None, 1, contained=True),
                "left after the job close": lambda: run_result(("left", 1), 1),
                "a requested stop": lambda: run_result(("stopped", 1), 0),
                "survivors yet a passing result": lambda: run_result(("survivors", 1), 0),
                "no containment diagnostic": lambda: run_result(("survivors", 1), 1, contained=False),
                "the parent did not exit 0": lambda: run_result(("survivors", 1), 1, exit_row=3),
                "no parent exit row": lambda: run_result(("survivors", 1), 1, exit_row=None),
                "the child was never proven alive": lambda: run_result(("survivors", 1), 1, child=False),
            }.items():
                with self.subTest(row=label, defect=why):
                    self._unexpected_at(label, make)

    def test_a_short_control_is_expected_only_as_a_drained_pass(self):
        for label in ("ps1-short", "cmd-short"):
            for why, make in {
                "survivors": lambda: run_result(("survivors", 1), 1),
                "drained yet a failing result": lambda: run_result(("drained", 0), 1),
                "no structured census": lambda: run_result(None, 1),
                "the parent did not exit 0": lambda: run_result(("drained", 0), 0, exit_row=2),
                "the child was never proven alive": lambda: run_result(("drained", 0), 0, child=False),
            }.items():
                with self.subTest(row=label, defect=why):
                    self._unexpected_at(label, make)


# ---------------------------------------------------------------------------------------------------------- C ----
MARKER = "nonce-ong21-red"
BEFORE_LINES = ["msedgewebview2\t4244\t638967035511111111", "zigBrowser\t5632\t638967035522222222"]
SURVIVOR_LINE = "ws04-linger\t6060\t638967035599999999"
MODULE_OK = "\n".join([
    "ROW\tps1-linger\tEXPECTED\tsurvivors\t1", "ROW\tps1-short\tEXPECTED\tdrained\t0",
    "ROW\tcmd-linger\tEXPECTED\tsurvivors\t1", "ROW\tcmd-short\tEXPECTED\tdrained\t0",
    "PASS\twin-job-leak", "ASSERTS 28", ""])

_FAKE_SSH = r'''
import json, os, pathlib, re, sys
argv = sys.argv[1:]
with open(os.environ["ZB_FAKE_LOG"], "a") as f:
    f.write(json.dumps(["ssh", *argv]) + "\n")
st, remote = pathlib.Path(os.environ["ZB_FAKE_STATE"]), pathlib.Path(os.environ["ZB_FAKE_REMOTE"])
cmd = argv[-1]
def out(text, rc=0, err=""):
    sys.stdout.write(text); sys.stderr.write(err); sys.exit(rc)
def local(win):  # %USERPROFILE%\a\b -> <remote>/a/b
    return remote / win.replace("%USERPROFILE%\\", "").replace("\\", "/")
if ".gate-identity" in cmd:
    out(os.environ.get("ZB_FAKE_MARKER", "") + "\r\n")
if "Get-Process" in cmd:
    if os.environ.get("ZB_FAKE_CENSUS") == "fail":
        out("", 1, "census probe failed")
    lines = json.loads(os.environ["ZB_FAKE_BEFORE"])
    if (st / "module_ran").exists() and os.environ.get("ZB_FAKE_FINAL") == "changed":
        lines = lines + [os.environ["ZB_FAKE_SURVIVOR"]]
    out("\r\n".join(lines + ["END"]) + "\r\n")
if "Get-Item -LiteralPath" in cmd:
    rel = re.search(r"Join-Path \$env:USERPROFILE '([^']+)'", cmd).group(1)
    out(("DIR" if (remote / rel.replace("\\", "/")).is_dir() else "ABSENT") + "\r\n")
m = re.fullmatch(r'mkdir "([^"]+)"', cmd)
if m:
    if os.environ.get("ZB_FAKE_MKDIR") == "fail":
        out("", 1, "A subdirectory or file already exists.")
    local(m.group(1)).mkdir(parents=True)
    out("")
m = re.fullmatch(r'rmdir /s /q "([^"]+)"', cmd)
if m:
    if os.environ.get("ZB_FAKE_RMDIR") == "fail":
        out("", 5, "Access is denied.")
    import shutil
    shutil.rmtree(local(m.group(1)))
    out("")
m = re.fullmatch(r'if exist "([^"]+)" \(echo LEFT\) else \(echo GONE\)', cmd)
if m:
    out(("LEFT" if local(m.group(1)).exists() else "GONE") + "\r\n")
if "win_job_leak_rows.py" in cmd:
    (st / "module_ran").touch()
    out(pathlib.Path(os.environ["ZB_FAKE_MODULE_OUT"]).read_text(), int(os.environ.get("ZB_FAKE_MODULE_RC", "0")))
if cmd.startswith("schtasks /query"):
    out(os.environ.get("ZB_FAKE_TASKS", ""), int(os.environ.get("ZB_FAKE_TASKS_RC", "0")))
out("")
'''

_FAKE_SCP = r'''
import json, os, pathlib, shutil, sys
argv = sys.argv[1:]
with open(os.environ["ZB_FAKE_LOG"], "a") as f:
    f.write(json.dumps(["scp", *argv]) + "\n")
if os.environ.get("ZB_FAKE_SCP") == "fail":
    sys.stderr.write("scp: connection lost\n"); sys.exit(1)
dest = pathlib.Path(os.environ["ZB_FAKE_REMOTE"]) / argv[-1].split(":", 1)[1]
if not dest.is_dir():
    sys.stderr.write(f"scp: {dest}: No such file or directory\n"); sys.exit(1)
for src in (pathlib.Path(a) for a in argv[:-1] if not a.startswith("-") and os.path.exists(a)):
    if src.is_dir():
        shutil.copytree(src, dest / src.name, dirs_exist_ok=True)
    else:
        shutil.copy2(src, dest / src.name)
'''


class FakeTime:
    """The shared helper's clock: sleeping advances it (no real 60 s waits in the hostless run)."""

    def __init__(self):
        self.now = 1000.0

    def monotonic(self):
        return self.now

    def sleep(self, s):
        self.now += max(0.0, s)


class LinuxLiveDriver(unittest.TestCase):
    def setUp(self):
        self.td = pathlib.Path(tempfile.mkdtemp(prefix="zb-ong21-"))
        self.addCleanup(shutil.rmtree, self.td)  # bound now: a subTest re-runs setUp
        self.bin = self.td / "bin"; self.bin.mkdir()
        for name, body in (("ssh", _FAKE_SSH), ("scp", _FAKE_SCP)):
            (self.bin / name).write_text(f"#!{sys.executable} -I\n{body}"); (self.bin / name).chmod(0o755)
        self.state = self.td / "state"; self.state.mkdir()
        self.remote = self.td / "remote"; (self.remote / "zb" / "runs").mkdir(parents=True)
        self.log = self.td / "calls.log"; self.log.write_text("")
        self.module_out = self.td / "module.out"; self.module_out.write_text(MODULE_OK)
        self.helper = self.td / "build" / "ws04-linger.exe"; self.helper.parent.mkdir()
        self.helper.write_bytes(b"MZ ong21 fake helper " + os.urandom(8))
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.td), "TMPDIR": str(self.td),
            "ZB_WIN_GATE": "1", "ZB_WIN11_HOST": fake_transport.FAKE_WIN11_HOST, "ZB_WIN11_PORT": "2222",
            "ZB_WIN11_USER": "zbtext", "ZB_WIN11_KEY": str(self.td / "no-such-key"),
            "ZB_WIN11_KNOWN_HOSTS": str(self.td / "no-such-known-hosts"), "ZB_WIN11_MARKER": MARKER,
            "ZB_FAKE_LOG": str(self.log), "ZB_FAKE_STATE": str(self.state), "ZB_FAKE_REMOTE": str(self.remote),
            "ZB_FAKE_MARKER": MARKER, "ZB_FAKE_BEFORE": json.dumps(BEFORE_LINES), "ZB_FAKE_SURVIVOR": SURVIVOR_LINE,
            "ZB_FAKE_MODULE_OUT": str(self.module_out),
        }

    def calls(self):
        return [json.loads(l) for l in self.log.read_text().splitlines()]

    def go(self, argv=None, subprocess_proxy=None, partial=False, **fake):
        """Runs the real driver's main in-process; returns rc, stdout, stderr, the recorded census/cleanup calls."""
        drv = load(DRIVER, "job_leak_live_test_under_test")
        env = {**self.env, **fake}
        rec = {"census": [], "remove": [], "inside": False}
        real_census, real_remove = webview2_cleanup.census, webview2_cleanup.remove_after_webview2

        def census(run, timeout=None):
            result = real_census(run, timeout=timeout)
            if not rec["inside"]:
                rec["census"].append({"obj": result, "log_len": len(self.calls())})
            return result

        def remove(run, win_dir, before, *a, **k):
            rec["inside"] = True
            start = len(self.calls())
            try:
                ok, why = real_remove(run, win_dir, before, *a, **k)
            finally:
                rec["inside"] = False
            rec["remove"].append({"win_dir": win_dir, "before": before, "args": a, "kwargs": k, "ok": ok,
                                  "window": (start, len(self.calls()))})
            return ok, why

        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(webview2_cleanup, "census", census), \
                mock.patch.object(webview2_cleanup, "remove_after_webview2", remove), \
                mock.patch.object(webview2_cleanup, "time", FakeTime()), \
                (mock.patch.object(drv, "subprocess", subprocess_proxy) if subprocess_proxy
                 else contextlib.nullcontext()), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = drv.main(argv if argv is not None else ["--helper", str(self.helper)])
        calls = self.calls()
        problem = fake_transport.problem(env, calls, netns=False, partial_ok=partial)
        detail = f"\nrc={rc}\nstdout:\n{out.getvalue()}\nstderr:\n{err.getvalue()}\ncalls:\n" + \
            "\n".join(" ".join(c) for c in calls)
        self.assertIsNone(problem, "every call stays on TEST-NET with keys that do not exist" + detail)
        self.assertFalse([c for c in calls if KILLS.search(" ".join(c))], "no kill of any kind" + detail)
        self.assertTrue(all(c[c.index("-i") + 1] == env["ZB_WIN11_KEY"] for c in calls if "-i" in c),
                        "only the explicit ZB_WIN11_KEY is used" + detail)
        return rc, out.getvalue(), err.getvalue(), rec, calls, detail

    @staticmethod
    def _cmd(c):
        return c[-1] if c[0] == "ssh" else ""

    def made_dir(self, calls):
        mk = [re.fullmatch(r'mkdir "(.+)\\tmp"', self._cmd(c)) for c in calls]
        mk = [m.group(1) for m in mk if m]
        return mk[0] if len(mk) == 1 else None

    def assert_one_cleanup(self, rec, calls, detail):
        """Exactly one shared-helper cleanup of this run's own folder, with the unchanged before-census object;
        every rmdir happens inside it, at most once."""
        self.assertEqual(len(rec["census"]), 1, "one before-census outside the cleanup" + detail)
        self.assertEqual(len(rec["remove"]), 1, "exactly one remove_after_webview2" + detail)
        r = rec["remove"][0]
        self.assertIs(r["before"], rec["census"][0]["obj"], "the SAME before-census object reaches the cleanup" + detail)
        self.assertEqual(r["win_dir"], self.made_dir(calls), "its own exact run folder" + detail)
        self.assertRegex(r["win_dir"], r"^%USERPROFILE%\\zb\\runs\\m8-[0-9]+-[0-9a-f]{12}$", detail)
        self.assertEqual(r["kwargs"].get("deadline_s", webview2_cleanup.DEADLINE_S), webview2_cleanup.DEADLINE_S,
                         "the production cleanup budget" + detail)
        rm = [i for i, c in enumerate(calls) if self._cmd(c).startswith("rmdir")]
        lo, hi = r["window"]
        self.assertTrue(all(lo <= i < hi for i in rm), "no raw rmdir outside the shared helper" + detail)
        self.assertLessEqual(len(rm), 1, "never a second deletion" + detail)
        return r

    def test_a_full_run_passes_only_with_the_census_cleanup_and_postchecks(self):
        rc, out, err, rec, calls, detail = self.go()
        self.assertEqual(rc, 0, detail)
        r = self.assert_one_cleanup(rec, calls, detail)
        self.assertTrue(r["ok"], detail)
        self.assertFalse((self.remote / r["win_dir"].replace("%USERPROFILE%\\", "").replace("\\", "/")).exists(),
                         "the run folder is gone" + detail)
        self.assertIn(f"RESULT\twin11\twin-job-leak\tPASS\t", out, detail)
        n = re.findall(r"^ASSERTS (\d+)$", out, re.M)
        self.assertEqual(len(n), 1, "exactly one ASSERTS line" + detail)
        self.assertGreater(int(n[0]), 0, detail)
        self.assertTrue(any(self._cmd(c).startswith("schtasks /query") for c in calls), "the task postcheck" + detail)

    def test_the_before_census_precedes_every_create_stage_and_launch(self):
        rc, _, _, rec, calls, detail = self.go()
        self.assertEqual(len(rec["census"]), 1, detail)
        first = rec["census"][0]["log_len"] - 1  # the census call itself is the last logged call at that moment
        acts = [i for i, c in enumerate(calls)
                if c[0] == "scp" or self._cmd(c).startswith("mkdir") or "win_job_leak_rows.py" in self._cmd(c)]
        self.assertTrue(acts, detail)
        self.assertLess(first, min(acts), "the baseline is taken before anything of the run exists" + detail)

    def test_the_run_stages_exactly_its_inputs_and_runs_the_module_inside_the_folder(self):
        rc, _, _, rec, calls, detail = self.go(ZB_FAKE_RMDIR="fail")  # keep the folder to inspect what was staged
        win_dir = self.made_dir(calls)
        self.assertIsNotNone(win_dir, detail)
        staged = self.remote / win_dir.replace("%USERPROFILE%\\", "").replace("\\", "/")
        self.assertEqual((staged / "ws04-linger.exe").read_bytes(), self.helper.read_bytes(), detail)
        for name in ("slice2_common.py", "win_job_leak_rows.py"):
            self.assertEqual((staged / "tests" / "e2e" / name).read_bytes(), (E2E / name).read_bytes(), detail)
        run = [self._cmd(c) for c in calls if "win_job_leak_rows.py" in self._cmd(c)]
        self.assertEqual(len(run), 1, "the module runs once" + detail)
        self.assertIn(f'cd /d "{win_dir}"', run[0], detail)
        self.assertIn(f'set "TEMP={win_dir}\\tmp"', run[0], detail)
        self.assertIn('set "ZB_WIN_GATE=1"', run[0], detail)
        self.assertIn("--helper ws04-linger.exe", run[0], detail)

    def test_every_failure_after_the_create_still_cleans_up_exactly_once(self):
        tasks_left = '"\\zb_m8_4242_0123abcd","N/A","Ready"\r\n'
        bad_outputs = {
            "a lingering row drained": MODULE_OK.replace("ROW\tps1-linger\tEXPECTED\tsurvivors\t1",
                                                         "ROW\tps1-linger\tEXPECTED\tdrained\t0"),
            "a short row with survivors": MODULE_OK.replace("ROW\tcmd-short\tEXPECTED\tdrained\t0",
                                                            "ROW\tcmd-short\tEXPECTED\tsurvivors\t1"),
            "a row missing": MODULE_OK.replace("ROW\tcmd-linger\tEXPECTED\tsurvivors\t1\n", ""),
            "rows out of order": MODULE_OK.replace("ps1-short", "TMP").replace("ps1-linger", "ps1-short")
                                          .replace("TMP", "ps1-linger"),
            "an unexpected row": "ROW\tps1-linger\tUNEXPECTED\tdrained 0\n",
            "no PASS row": MODULE_OK.replace("PASS\twin-job-leak\n", ""),
            "zero asserts": MODULE_OK.replace("ASSERTS 28", "ASSERTS 0"),
        }
        cases = {**{k: ({}, v, "0") for k, v in bad_outputs.items()},
                 "the module failed": ({}, MODULE_OK, "1"),
                 "staging failed": ({"ZB_FAKE_SCP": "fail"}, MODULE_OK, "0"),
                 "a task left behind": ({"ZB_FAKE_TASKS": tasks_left}, MODULE_OK, "0"),
                 "the task query failed": ({"ZB_FAKE_TASKS_RC": "1"}, MODULE_OK, "0")}
        for why, (fake, module_out, module_rc) in cases.items():
            with self.subTest(case=why):
                self.setUp()
                self.module_out.write_text(module_out)
                rc, out, _, rec, calls, detail = self.go(ZB_FAKE_MODULE_RC=module_rc, **fake)
                self.assertEqual(rc, 1, detail)
                self.assertNotIn("\tPASS\t", out, detail)
                r = self.assert_one_cleanup(rec, calls, detail)
                self.assertTrue(r["ok"], "the folder is still removed" + detail)

    def test_a_module_timeout_still_cleans_up_exactly_once(self):
        real = subprocess

        class Proxy:
            TimeoutExpired = real.TimeoutExpired
            CompletedProcess = real.CompletedProcess
            DEVNULL, PIPE = real.DEVNULL, real.PIPE
            seen = []

            def run(self, argv, *a, **k):
                if "win_job_leak_rows.py" in " ".join(map(str, argv)):
                    Proxy.seen.append(k.get("timeout"))
                    raise real.TimeoutExpired(argv, k.get("timeout"))
                return real.run(argv, *a, **k)

            def __getattr__(self, name):
                return getattr(real, name)

        rc, out, _, rec, calls, detail = self.go(subprocess_proxy=Proxy())
        self.assertEqual(rc, 1, detail)
        self.assertEqual(len(Proxy.seen), 1, detail)
        self.assertTrue(Proxy.seen[0] is not None and 200 <= Proxy.seen[0] <= 1800,
                        f"the module run is bounded, with room for four rows: {Proxy.seen[0]}" + detail)
        self.assertTrue(self.assert_one_cleanup(rec, calls, detail)["ok"], detail)

    def test_a_changed_final_census_or_a_failed_removal_fails_the_run(self):
        for why, fake in {"a survivor in the final census": {"ZB_FAKE_FINAL": "changed"},
                          "the removal failed": {"ZB_FAKE_RMDIR": "fail"}}.items():
            with self.subTest(case=why):
                self.setUp()
                rc, out, err, rec, calls, detail = self.go(**fake)
                self.assertEqual(rc, 1, detail)
                self.assertNotIn("\tPASS\t", out, detail)
                r = self.assert_one_cleanup(rec, calls, detail)
                self.assertFalse(r["ok"], detail)
                if "survivor" in why:
                    self.assertFalse([c for c in calls if self._cmd(c).startswith("rmdir")],
                                     "nothing is deleted while the census differs" + detail)

    def test_a_failed_create_deletes_nothing(self):
        rc, _, _, rec, calls, detail = self.go(ZB_FAKE_MKDIR="fail")
        self.assertEqual(rc, 1, detail)
        self.assertEqual(rec["remove"], [], "a folder this run did not create is never cleaned" + detail)
        self.assertFalse([c for c in calls if c[0] == "scp" or "win_job_leak_rows.py" in self._cmd(c)], detail)

    def test_no_create_before_the_identity_and_the_census_hold(self):
        for why, fake in {"wrong host": {"ZB_FAKE_MARKER": "someone-else"},
                          "unreadable census": {"ZB_FAKE_CENSUS": "fail"}}.items():
            with self.subTest(case=why):
                self.setUp()
                rc, _, _, rec, calls, detail = self.go(**fake)
                self.assertEqual(rc, 1, detail)
                self.assertEqual(rec["remove"], [], detail)
                self.assertFalse([c for c in calls if self._cmd(c).startswith("mkdir") or c[0] == "scp"], detail)

    def test_the_explicit_win11_contract_is_complete_before_any_transport(self):
        for var in ("ZB_WIN11_PORT", "ZB_WIN11_USER", "ZB_WIN11_KEY", "ZB_WIN11_KNOWN_HOSTS", "ZB_WIN11_MARKER"):
            with self.subTest(missing=var):
                self.setUp()
                self.env.pop(var)
                # legacy selector bait: never a fallback
                self.env.update({"ZB_WIN_KEY": str(self.td / "legacy-key"),
                                 "ZB_WIN_KNOWN_HOSTS": str(self.td / "legacy-kh")})
                rc, _, err, rec, calls, detail = self.go(partial=True)
                self.assertEqual(rc, 2, detail)
                self.assertIn("refused:", err, detail)
                self.assertIn(var, err, detail)
                self.assertEqual(calls, [], "no transport call under a partial configuration" + detail)

    def test_no_host_or_no_helper_is_a_failure_under_the_gate_and_a_skip_standalone(self):
        for why, change, argv in (("no host", ("ZB_WIN11_HOST",), None),
                                  ("no helper", (), ["--helper", "/nonexistent/ws04-linger.exe"])):
            for gate, want in (("1", 1), (None, 77)):
                with self.subTest(case=why, gate=gate):
                    self.setUp()
                    for k in change:
                        self.env.pop(k)
                    if gate is None:
                        self.env.pop("ZB_WIN_GATE")
                    rc, _, _, rec, calls, detail = self.go(argv=argv)
                    self.assertEqual(rc, want, detail)
                    self.assertEqual(calls, [], detail)

    def test_win10_selectors_are_never_contacted(self):
        self.env.update({"ZB_WIN10_HOST": fake_transport.FAKE_WIN10_HOST, "ZB_WIN10_PORT": "22",
                         "ZB_WIN10_USER": "zbtest", "ZB_WIN10_KEY": str(self.td / "no-w10-key"),
                         "ZB_WIN10_KNOWN_HOSTS": str(self.td / "no-w10-kh"), "ZB_WIN10_MARKER": "w10"})
        rc, _, _, rec, calls, detail = self.go()
        self.assertEqual(rc, 0, detail)
        self.assertFalse([c for c in calls if any(fake_transport.FAKE_WIN10_HOST in a for a in c)],
                         "this proof runs on Win11 only" + detail)


if __name__ == "__main__":
    unittest.main()
