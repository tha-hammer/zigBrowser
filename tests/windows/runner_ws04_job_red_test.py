#!/usr/bin/env python3
"""WS0.4 RED (UNREGISTERED): the scheduled-task runner owns its process tree in a job and proves it gone.

Plan rev 2.21, WS0.4 ("kills its job"; Testing Strategy: "a hard time bound, and job-object cleanup"). The Win11 m8
run at 2df192b (approval 1570d49) left a WebView2 process holding
runs\\m8-*\\zigBrowser.exe.WebView2\\EBWebView\\lockfile after the tests returned, so the driver's cleanup failed. The
m8 tests share that user-data folder, so a WebView2 tree that outlives one test can also meet the next one.

Contract this red pins (the Python half of the runner; the PowerShell job wrapper is proven on the VM):
  - the task wrapper reports one job census in <work>/job.txt: `ZB_RUNNER_JOB\t<verdict>\t<n>`, where verdict is
    `drained` (the tree exited by itself), `killed` (the leftovers were terminated; n were killed) or `left`
    (n processes survived the kill);
  - no census => the run FAILS ("no job census"); `left` => the run FAILS naming n; `killed` => the run passes and
    the kill is reported; `drained` => the run passes;
  - to stop a still-running task the runner asks the wrapper (<work>/stop.txt) and waits for its census; it does not
    taskkill the tree by pid;
  - the cmd runner uses the same job wrapper and census.

Hostless: drives the REAL slice2_common runners in a child Python with a recording fake schtasks/taskkill (a variant
of gate_selftest.py's WS0.4 fake that also plays the job wrapper's census) and the same `os` proxy. The green moves
these cases into gate_selftest.py (step windows-gate-selftest).

Run alone:  python3 -I tests/windows/runner_ws04_job_red_test.py -v
"""
import json
import pathlib
import shlex
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]

# The WS0.4 fake, plus the job wrapper's side: ZB_FAKE_JOB = none | drained | killed | left | stop.
#   none/drained/killed/left: /run finishes the task at once and (except none) writes that census;
#   stop: /run leaves the task running; a background helper waits for <work>/stop.txt, then writes `killed 1`,
#         the exit code and the harness row, as the wrapper does when the runner asks it to stop.
_FAKE_SCHTASKS = r"""#!/usr/bin/env bash
printf 'schtasks' >> "$ZB_FAKE_LOG"; printf ' %q' "$@" >> "$ZB_FAKE_LOG"; printf '\n' >> "$ZB_FAKE_LOG"
verb="$1"; shift
tn=""; tr=""
while [ $# -gt 0 ]; do
  case "$1" in
    /tn) tn="$2"; shift 2 ;;
    /tr) tr="$2"; shift 2 ;;
    *) shift ;;
  esac
done
finish() { # $1 = dir: what the wrapper writes when its task is done
  printf 'PASS\tfake\nZB_HARNESS_EXIT\t0\n' >> "$1/stdout.txt"; echo 0 > "$1/exit.txt"
}
case "$verb" in
  /create) printf '%s' "$tr" > "$ZB_FAKE_STATE/$tn.tr"; exit 0 ;;
  /run)
    script=$(sed -E 's/.*"([^"]+)"[^"]*$/\1/' "$ZB_FAKE_STATE/$tn.tr"); dir=$(dirname "$script")
    : > "$dir/stdout.txt"; : > "$dir/stderr.txt"; echo 4242 > "$dir/pid.txt"
    case "${ZB_FAKE_JOB:-none}" in
      none) finish "$dir" ;;
      drained|killed|left)
        n=0; [ "$ZB_FAKE_JOB" = drained ] || n=2
        printf 'ZB_RUNNER_JOB\t%s\t%s\n' "$ZB_FAKE_JOB" "$n" > "$dir/job.txt"; finish "$dir" ;;
      stop)
        printf 'READY\tfake\n' >> "$dir/stdout.txt"
        ( for i in $(seq 1 300); do [ -e "$dir/stop.txt" ] && break; sleep 0.1; done
          [ -e "$dir/stop.txt" ] && { printf 'ZB_RUNNER_JOB\tkilled\t1\n' > "$dir/job.txt"; finish "$dir"; } ) \
          > /dev/null 2>&1 < /dev/null &
        ;;
    esac
    exit 0 ;;
  /end|/delete) exit 0 ;;
esac
exit 0
"""
_FAKE_TASKKILL = r"""#!/usr/bin/env bash
printf 'taskkill' >> "$ZB_FAKE_LOG"; printf ' %q' "$@" >> "$ZB_FAKE_LOG"; printf '\n' >> "$ZB_FAKE_LOG"
exit 0
"""

_CHILD = r"""
import json, os, sys, pathlib
sys.path.insert(0, sys.argv[1])
import slice2_common as s

class _WindowsName:
    name = "nt"
    def __getattr__(self, attr):
        return getattr(os, attr)

s.os = _WindowsName()
which, until_ready = sys.argv[2], sys.argv[3] == "ready"
cond = (lambda o, e, p: any(l.startswith("READY") for l in o)) if until_ready else (lambda o, e, p: p.returncode is not None)
if which == "ps1":
    matched, r = s.run_windows_interactive_until(["C:\\zb\\fake.exe"], {}, 20, cond, cwd=pathlib.Path.cwd())
else:
    matched, r = s.run_windows_interactive_cmd_until(["C:\\zb\\fake.exe"], {}, 20, cond, cwd=pathlib.Path.cwd())
print(json.dumps({"matched": matched, "returncode": r.returncode, "stderr": r.stderr_lines}))
"""


class RunnerOwnsItsJobRed(unittest.TestCase):
    def _run(self, which, job, until="exit"):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir()
            state = td / "state"; state.mkdir()
            for name, body in (("schtasks", _FAKE_SCHTASKS), ("taskkill", _FAKE_TASKKILL)):
                (bindir / name).write_text(body); (bindir / name).chmod(0o755)
            log = td / "calls.log"; log.write_text("")
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td),
                   "ZB_FAKE_LOG": str(log), "ZB_FAKE_STATE": str(state), "ZB_FAKE_JOB": job}
            proc = subprocess.run(["python3", "-I", "-c", _CHILD, str(REPO / "tests" / "e2e"), which, until], cwd=td,
                                  env=env, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
            calls = [shlex.split(c) for c in log.read_text().splitlines()]
            stops = list(td.glob("zb_m8_*/stop.txt"))
        detail = (f"\nchild rc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls:\n"
                  + "\n".join(map(shlex.join, calls)))
        self.assertEqual(proc.returncode, 0, "the child driver itself must not crash" + detail)
        return json.loads(proc.stdout.strip().splitlines()[-1]), calls, stops, detail

    def test_no_job_census_fails_the_run(self):
        for which in ("ps1", "cmd"):
            with self.subTest(runner=which):
                result, _, _, detail = self._run(which, "none")
                self.assertNotEqual(result["returncode"], 0, "a run with no job census proves nothing gone" + detail)
                self.assertTrue(any("no job census" in l for l in result["stderr"]), detail)

    def test_processes_left_after_the_kill_fail_the_run(self):
        for which in ("ps1", "cmd"):
            with self.subTest(runner=which):
                result, _, _, detail = self._run(which, "left")
                self.assertNotEqual(result["returncode"], 0, detail)
                self.assertTrue(any("2 process(es) of the run survived" in l for l in result["stderr"]), detail)

    def test_a_drained_or_killed_job_passes_and_a_kill_is_reported(self):
        for which in ("ps1", "cmd"):
            for job, reported in (("drained", False), ("killed", True)):
                with self.subTest(runner=which, job=job):
                    result, _, _, detail = self._run(which, job)
                    self.assertEqual(result["returncode"], 0, detail)
                    self.assertEqual(any("killed 2 leftover process(es)" in l for l in result["stderr"]), reported, detail)

    def test_a_running_task_is_stopped_through_its_job_not_by_pid(self):
        result, calls, stops, detail = self._run("ps1", "stop", until="ready")
        self.assertTrue(result["matched"], detail)
        self.assertEqual(len(stops), 1, "the runner asks the wrapper to stop (stop.txt)" + detail)
        self.assertFalse([c for c in calls if c[:1] == ["taskkill"]], "no pid-based tree kill" + detail)
        self.assertEqual(result["returncode"], 0, "the wrapper's census came back: killed 1" + detail)

    def test_the_cmd_runner_runs_under_the_same_job_wrapper(self):
        _, calls, _, detail = self._run("cmd", "drained")
        creates = [c for c in calls if c[:2] == ["schtasks", "/create"]]
        self.assertEqual(len(creates), 1, detail)
        tr = creates[0][creates[0].index("/tr") + 1]
        self.assertTrue(tr.startswith("powershell.exe ") and tr.rstrip('"').endswith(".ps1"),
                        "the cmd task runs through the PowerShell job wrapper" + detail)


if __name__ == "__main__":
    unittest.main()
