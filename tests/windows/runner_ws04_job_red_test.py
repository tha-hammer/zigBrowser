#!/usr/bin/env python3
"""WS0.4 RED (UNREGISTERED), revised per NavyCanyon 7eafbae option (a): the runner WAITS for its job to drain.

Plan rev 2.21, WS0.4 ("kills its job"; Testing Strategy: "a hard time bound, and job-object cleanup"). The Win11 m8
run at 2df192b left a WebView2 process holding runs\\m8-*\\zigBrowser.exe.WebView2\\EBWebView\\lockfile after the
tests returned. 25fa071 accepted a `killed` census as a pass; 7eafbae blocks that. This red supersedes it.

Contract (the Python half of the runner; the PowerShell job wrapper is proven on the VM):
  - the program runs in an owned job; the task wrapper writes ONE census line to <work>/job.txt:
    `ZB_RUNNER_JOB\t<verdict>\t<n>`;
  - after a normal test exit the wrapper waits, within one total deadline of at most 60 s
    (slice2_common.JOB_DRAIN_DEADLINE_SEC), for the job to drain by itself:
      `drained\t0`     -> the only natural-exit verdict that passes;
      `survivors\t<n>` -> n processes were still alive at the deadline: recorded, and the run FAILS. The wrapper
                          may then close the job to contain them, but that never turns the row into a pass;
      `left\t<n>`      -> n processes outlived even the job close: FAIL;
  - the runner may end its own still-running test through the job (it writes <work>/stop.txt; the wrapper
    closes the job and writes `stopped\t<n>`) after a matched stop condition or a hard timeout. A matched stop
    passes; a timeout stays a failure;
  - a missing census, an unknown verdict, a malformed line or a count that contradicts its verdict FAILS;
  - there is no pid taskkill, ever (not as a fallback when the wrapper does not answer);
  - the cmd runner uses the same wrapper and the same rules.
  PinkOwl's shared WebView2 helper (tests/windows/webview2_cleanup.py, 0c48276) follows the same shape: bounded
  wait of at most 60 s, never kill, fail closed.

Hostless: drives the REAL slice2_common runners in a child Python with a recording fake schtasks/taskkill that also
plays the job wrapper, and an `os` proxy whose name is "nt". The child shortens the drain deadline for speed. The
green moves these cases into gate_selftest.py (step windows-gate-selftest).

Run alone:  python3 -I tests/windows/runner_ws04_job_red_test.py -v
"""
import json
import pathlib
import shlex
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]

# ZB_FAKE_JOB picks what the fake wrapper does once /run starts the task:
#   none            the test exits, no census;
#   census:<line>   the test exits and the wrapper writes job.txt = <line> (tabs given as \t);
#   late            the test exits, then `drained 0` arrives 1.5 s later (inside the runner's deadline);
#   stop            the test keeps running and prints READY; on stop.txt the wrapper writes `stopped 1` and exits;
#   deaf            the test keeps running and prints READY; the wrapper never answers stop.txt.
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
finish() { # $1 = dir: what the wrapper writes when its test is done
  printf 'PASS\tfake\nZB_HARNESS_EXIT\t0\n' >> "$1/stdout.txt"; echo 0 > "$1/exit.txt"
}
case "$verb" in
  /create) printf '%s' "$tr" > "$ZB_FAKE_STATE/$tn.tr"; exit 0 ;;
  /run)
    script=$(sed -E 's/.*"([^"]+)"[^"]*$/\1/' "$ZB_FAKE_STATE/$tn.tr"); dir=$(dirname "$script")
    : > "$dir/stdout.txt"; : > "$dir/stderr.txt"; echo 4242 > "$dir/pid.txt"
    mode="${ZB_FAKE_JOB:-none}"
    case "$mode" in
      none) finish "$dir" ;;
      census:*) printf "${mode#census:}\n" > "$dir/job.txt"; finish "$dir" ;;
      late)
        finish "$dir"
        ( sleep 1.5; printf 'ZB_RUNNER_JOB\tdrained\t0\n' > "$dir/job.txt" ) > /dev/null 2>&1 < /dev/null & ;;
      stop|deaf)
        printf 'READY\tfake\n' >> "$dir/stdout.txt"
        if [ "$mode" = stop ]; then
          ( for i in $(seq 1 300); do [ -e "$dir/stop.txt" ] && break; sleep 0.1; done
            [ -e "$dir/stop.txt" ] && { printf 'ZB_RUNNER_JOB\tstopped\t1\n' > "$dir/job.txt"; echo 1 > "$dir/exit.txt"; } ) \
            > /dev/null 2>&1 < /dev/null &
        fi ;;
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
real_deadline = getattr(s, "JOB_DRAIN_DEADLINE_SEC", None)
s.JOB_DRAIN_DEADLINE_SEC = 3.0          # the wrapper's drain deadline, shortened for a hostless run
s.JOB_CENSUS_GRACE_SEC = 1.0
which, until, timeout = sys.argv[2], sys.argv[3], float(sys.argv[4])
cond = {
    "exit": lambda o, e, p: p.returncode is not None,
    "ready": lambda o, e, p: any(l.startswith("READY") for l in o),
    "never": lambda o, e, p: False,
}[until]
runner = s.run_windows_interactive_until if which == "ps1" else s.run_windows_interactive_cmd_until
matched, r = runner(["C:\\zb\\fake.exe"], {}, timeout, cond, cwd=pathlib.Path.cwd())
print(json.dumps({"matched": matched, "returncode": r.returncode, "stderr": r.stderr_lines,
                  "timed_out": r.timed_out, "real_deadline": real_deadline}))
"""

RUNNERS = ("ps1", "cmd")


class RunnerWaitsForItsJobRed(unittest.TestCase):
    def _run(self, which, job, until="exit", timeout=20.0):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir()
            state = td / "state"; state.mkdir()
            for name, body in (("schtasks", _FAKE_SCHTASKS), ("taskkill", _FAKE_TASKKILL)):
                (bindir / name).write_text(body); (bindir / name).chmod(0o755)
            log = td / "calls.log"; log.write_text("")
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td),
                   "ZB_FAKE_LOG": str(log), "ZB_FAKE_STATE": str(state), "ZB_FAKE_JOB": job}
            proc = subprocess.run(["python3", "-I", "-c", _CHILD, str(REPO / "tests" / "e2e"), which, until,
                                   str(timeout)], cwd=td, env=env, capture_output=True, text=True, timeout=120,
                                  stdin=subprocess.DEVNULL)
            calls = [shlex.split(c) for c in log.read_text().splitlines()]
            stops = list(td.glob("zb_m8_*/stop.txt"))
        detail = (f"\nchild rc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls:\n"
                  + "\n".join(map(shlex.join, calls)))
        self.assertEqual(proc.returncode, 0, "the child driver itself must not crash" + detail)
        result = json.loads(proc.stdout.strip().splitlines()[-1])
        self.assertFalse([c for c in calls if c[:1] == ["taskkill"]], "no pid taskkill, ever" + detail)
        return result, calls, stops, detail

    def _fails_with(self, job, needle, until="exit", timeout=20.0):
        for which in RUNNERS:
            with self.subTest(runner=which, job=job):
                result, _, _, detail = self._run(which, job, until, timeout)
                self.assertNotEqual(result["returncode"], 0, f"census {job!r} must fail the run" + detail)
                self.assertTrue(any(needle in l for l in result["stderr"]), f"expected {needle!r}" + detail)

    def test_drain_deadline_is_at_most_60_s(self):
        result, _, _, detail = self._run("ps1", r"census:ZB_RUNNER_JOB\tdrained\t0")
        self.assertIsNotNone(result["real_deadline"], "slice2_common.JOB_DRAIN_DEADLINE_SEC is the one deadline" + detail)
        self.assertTrue(0 < result["real_deadline"] <= 60, detail)

    def test_a_naturally_drained_job_passes(self):
        for which in RUNNERS:
            for job in (r"census:ZB_RUNNER_JOB\tdrained\t0", "late"):
                with self.subTest(runner=which, job=job):
                    result, _, _, detail = self._run(which, job)
                    self.assertEqual(result["returncode"], 0, detail)

    def test_survivors_at_the_deadline_fail_even_once_contained(self):
        self._fails_with(r"census:ZB_RUNNER_JOB\tsurvivors\t2", "2 process(es) of the run were still alive")

    def test_processes_left_after_the_job_close_fail(self):
        self._fails_with(r"census:ZB_RUNNER_JOB\tleft\t2", "2 process(es) of the run survived")

    def test_a_kill_after_a_normal_exit_is_not_a_pass(self):
        # 25fa071's `killed` verdict is gone: after a normal exit only a natural drain passes
        self._fails_with(r"census:ZB_RUNNER_JOB\tkilled\t2", "invalid job census")

    def test_a_missing_census_fails(self):
        self._fails_with("none", "no job census")

    def test_an_invalid_census_fails(self):
        for line in (r"census:ZB_RUNNER_JOB\tdrained\t3", r"census:ZB_RUNNER_JOB\tsurvivors\t0",
                     r"census:ZB_RUNNER_JOB\tdrained", r"census:ZB_RUNNER_JOB\tdrained\tx",
                     r"census:junk", r"census:ZB_RUNNER_JOB\tdrained\t0\nZB_RUNNER_JOB\tdrained\t0"):
            self._fails_with(line, "invalid job census")

    def test_a_matched_stop_ends_the_test_through_its_job(self):
        for which in RUNNERS:
            with self.subTest(runner=which):
                result, _, stops, detail = self._run(which, "stop", until="ready")
                self.assertTrue(result["matched"], detail)
                self.assertEqual(len(stops), 1, "the runner asks the wrapper to stop (stop.txt)" + detail)
                self.assertEqual(result["returncode"], 0, "a matched stop with a `stopped` census passes" + detail)

    def test_a_timeout_stops_through_the_job_and_stays_a_failure(self):
        for which in RUNNERS:
            with self.subTest(runner=which):
                result, _, stops, detail = self._run(which, "stop", until="never", timeout=2.0)
                self.assertTrue(result["timed_out"], detail)
                self.assertEqual(len(stops), 1, "the runner ends its timed-out test through the job" + detail)
                self.assertNotEqual(result["returncode"], 0, "a timeout stays a failure" + detail)

    def test_a_wrapper_that_never_answers_fails_without_a_pid_fallback(self):
        self._fails_with("deaf", "no job census", until="never", timeout=2.0)

    def test_the_cmd_runner_runs_under_the_same_job_wrapper(self):
        _, calls, _, detail = self._run("cmd", r"census:ZB_RUNNER_JOB\tdrained\t0")
        creates = [c for c in calls if c[:2] == ["schtasks", "/create"]]
        self.assertEqual(len(creates), 1, detail)
        tr = creates[0][creates[0].index("/tr") + 1]
        self.assertTrue(tr.startswith("powershell.exe ") and tr.rstrip('"').endswith(".ps1"),
                        "the cmd task runs through the PowerShell job wrapper" + detail)


if __name__ == "__main__":
    unittest.main()
